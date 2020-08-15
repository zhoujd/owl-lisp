(define-library (owl eval env)

   (export
      lookup env-bind
      empty-env
      apply-env env-fold
      verbose-vm-error prim-opcodes opcode->wrapper primop-of primitive?
      poll-tag name-tag link-tag buffer-tag signal-tag thread-quantum meta-tag
      current-library-key
      env-set-macro *tabula-rasa* env-del
      env-get ;; env key default → val | default
      env-del ;; env key → env'
      env-set ;; env-set env key val → env'
      env-keep ;; env (name → name' | #false) → env'
      env-get-raw ;; env key → value      -- temporary
      env-put-raw ;; env key value → env' -- temporary
      env-keys ;; env → (key ...)
      )

   (import
      (owl core)
      (owl lcd ff)
      (owl function)
      (owl list)
      (owl tuple)
      (owl symbol)
      (owl string)
      (owl render)
      (owl equal)
      (owl math)
      (owl io)
      (owl port)
      (owl eval data)
      (scheme base)
      (scheme cxr)
      (owl primop))

   (begin

      (define empty-env empty) ;; will change with ff impl

      (define env-del del)

      (define poll-tag "mcp/polls")
      (define buffer-tag "mcp/buffs")
      (define link-tag "mcp/links")
      (define signal-tag "mcp/break")
      (define meta-tag '*owl-metadata*) ; key for object metadata
      (define name-tag '*owl-names*)    ; key for reverse function/object → name mapping
      (define current-library-key '*owl-source*) ; toplevel value storing what is being loaded atm

      (define thread-quantum 10000)

      (define lookup ;; <- to be replaced with env-get
         (let ((undefined (tuple 'undefined)))
            (λ (env key)
               (get env key undefined))))

      ;; get a value from env, or return def if not there or not a value
      (define (env-get env key def)
         (tuple-case (lookup env key)
            ((defined val)
               (tuple-case val
                  ((value v) v)
                  (else def)))
            (else def)))

      (define env-get-raw get)

      (define env-put-raw put)

      (define (env-set env key val)
         (put env key
            (tuple 'defined
               (tuple 'value val))))

      (define (env-set-macro env key transformer)
         (put env key
            (tuple 'macro transformer)))

      (define-syntax invoke
         (syntax-rules ()
            ((invoke module name arg ...)
               ((env-get module (quote name)
                  (λ (arg ...)
                     (error "invoke: failed to invoke "
                        (cons (quote name)
                           (list arg ...)))))
                  arg ...))))

      ;; mark an argument list (possibly improper list of symbols) as bound
      (define env-bind
         (let ((bound (tuple 'bound)))
            (λ (env keys)
               (let loop ((env env) (keys keys))
                  (cond
                     ((null? keys) env)
                     ((pair? keys)
                        (loop (put env (car keys) bound) (cdr keys)))
                     (else ;; improper argument list
                        (put env keys bound)))))))

      ;;;
      ;;; apply-env
      ;;;

      ; this compiler pass maps sexps to sexps where each free
      ; occurence of a variable is replaced by it's value

      ; this is functionally equivalent to making a big
      ; (((lambda (name ..) exp) value)), but the compiler currently
      ; handles values occurring in the sexp itself a bit more efficiently

      (define (value-exp val)
         ; represent the literal value val safely as an s-exp
         (if (or (pair? val) (symbol? val))
            (list 'quote val)
            val))

      (define (handle-symbol exp env fail)
         ;(print (list 'handle-symbol exp 'being (lookup env exp)))
         (tuple-case (lookup env exp)
            ((bound) exp)
            ((defined defn)
               (tuple-case defn
                  ((value val)
                     (value-exp val))
                  (else is funny
                     (fail (list "funny defined value: " funny)))))
            ((undefined)
               (fail (list "What is"
                  (bytes->string (foldr render '() (list "'" exp "'?"))))))
            (else is bad
               (fail (list "The symbol" exp "has a funny value: '" bad "'")))))

      (define (formals-cool? call)
         (let ((formals (cadr call)))
            (let loop ((formals formals))
               (cond
                  ((and (pair? formals) (symbol? (car formals)))
                     (loop (cdr formals)))
                  ((symbol? formals) #true)
                  ((null? formals) #true)
                  (else #false)))))

      (define (walker env fail)
         (define (walk exp)
            ; (print (list 'walk exp))
            (cond
               ((null? exp)
                  ; allow null as a self-evaluating form
                  (list 'quote exp))
               ((list? exp)
                  (case (car exp)
                     ((lambda)
                        (if (and (= (length exp) 3) (formals-cool? exp))
                           (list 'lambda (cadr exp)
                              ((walker (env-bind env (cadr exp)) fail)
                                 (caddr exp)))
                           (fail (list "funny lambda: " exp))))
                     ((rlambda)
                        (if (and (= (length exp) 4) (formals-cool? exp))
                           (let ((walk (walker (env-bind env (cadr exp)) fail)))
                              (list 'rlambda
                                 (cadr exp)
                                 (map walk (caddr exp))
                                 (walk (car (cdddr exp)))))
                           (fail (list "funny rlambda: " (list exp 'len (length exp) 'forms (formals-cool? exp))))))
                     ((values receive _branch)
                        (cons (car exp)
                           (map walk (cdr exp))))
                     ((quote) exp)
                     (else
                        (map walk exp))))
               ((symbol? exp)
                  (handle-symbol exp env fail))
               ((pair? exp)
                  (fail (list "improper code: " exp)))
               ((number? exp)
                  exp)
               (else
                  (list 'quote exp))))
         walk)

      ; drop definitions from env to unbound occurrences in exp
      ; after macros have been expanded

      (define (apply-env exp env)
         (call/cc
            (λ (ret)
               (ok 
                  ((walker env (B ret fail)) exp)
                  env
                  ))))

      (define (env-fold o s ff)
         (ff-fold o s ff))

      (define (env-serializer env thing)
         ((make-serializer
            empty
           ; (env-get env name-tag empty)
           )
            thing #n))

      (define (verbose-vm-error env opcode a b)
         (case opcode
            ((61)
            ;; arity error, could be variable
            ; this is either a call, in which case it has an implicit continuation,
            ; or a return from a function which doesn't have it. it's usually a call,
            ; so -1 to not count continuation. there is no way to differentiate the
            ; two, since there are no calls and returns, just jumps.
               (let ((func (list->string (env-serializer env a))))
                  ;; use the updated renderer from toplevel to possibly get a name for the function
                  (cond
                     ((fixnum? b)
                        `(arity error ,func got ,b arguments))
                     ((function? (ref b 1))
                        `(arity error ,func arguments ,(cdr (tuple->list b))
                        or return arity error where first is function))
                     (else
                        `(wrong number of returned values ,(tuple->list b))))))
            ((0)
               `("error: bad call: operator" ,a "- args w/ cont" ,b))
            ((105)
               `("error: car on non-pair" ,a))
            ((169)
               `("error: cdr on non-pair" ,a))
            ((256)
               `("error: hit unimplemented opcode" ,a))
            (else
               `("error: instruction" ,(primop-name opcode) "reported error:" ,a ,b))))

      ;; ff of wrapper-fn → opcode
      (define prim-opcodes
         (fold
            (λ (ff node)
               (put ff (ref node 5) (ref node 2)))
            empty primops))

      ;; ff of opcode → wrapper
      (define opcode->wrapper
         (fold
            (λ (ff node)
               (put ff (ref node 2) (ref node 5)))
            empty primops))

      ;; later check type, get first opcode and compare to primop wrapper
      ;; move elsewhere
      (define (primop-of val)
         (cond
            ((get prim-opcodes val #false) => self)
            ((eq? val '__mkt__) 23) ;; temp hack to work around changing bytecode
            ((eq? val '__bind__) 32) ;; ditto
            (else #false)))

      ;; only special forms supported by the compiler, no primops etc
      (define *tabula-rasa*
         (->
            (list->ff
               (list
                  ;; special forms.
                  (cons 'lambda  (tuple 'special 'lambda))
                  (cons 'quote   (tuple 'special 'quote))
                  (cons 'rlambda (tuple 'special 'rlambda)) ;; letrec etc, removed in compilation
                  (cons 'receive (tuple 'special 'receive)) ;; generate continuation to receive multiple values during compilation
                  (cons '_branch (tuple 'special '_branch)) ;; if
                  (cons '_define (tuple 'special '_define)) ;; handled by repl
                  (cons 'values   (tuple 'special 'values)) ;; ends up as as regular call to continuation during compilation
                  ))
            ; (env-set 'syntax-transformer syntax-transformer)
            ))

      ;; take a subset of env
      ;; fixme - misleading name
      (define (env-keep env namer)
         (env-fold
            (λ (out name value)
               (let ((name (namer name)))
                  (if name (put out name value) out)))
            empty env))

      (define (env-keys env)
         (ff-fold (λ (words key value) (cons key words)) #n env))

      (define primitive? primop-of)
))
