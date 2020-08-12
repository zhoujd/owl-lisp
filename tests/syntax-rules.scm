
(define-library (macro test)

   (import
      (owl base)
      (owl syntax-rules))
   
   (export
      foo)
   
   (begin
   
      (define value 42)
      
      (define-syntax-ng foo
         (syntax-rules ()
            ((foo a b)
               ;; environment reference to non-exported value
               value)
            ((foo a)
               ;; recursion to old name
               (foo a a))))))

(import 
   (prefix (macro test) different-))

(define value 100)

(print (different-foo 1))

   
      
