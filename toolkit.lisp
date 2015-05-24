#|
 This file is a part of Qtools
 (c) 2014 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.qtools)
(named-readtables:in-readtable :qt)

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; We need this here so that we can use FIND-QCLASS.
  (ensure-smoke :qtcore)
  (ensure-smoke :qtgui))

;;;;;
;; Qt Related Utils

(defgeneric value (object)
  (:documentation "Returns the VALUE of object. This usually translates to (#_value object) unless overriden."))

(defmethod value ((object qobject))
  (#_value object))

(defgeneric (setf value) (value object)
  (:documentation "Sets the VALUE of object. This usually translates to (#_setValue object) unless overriden."))

(defmethod (setf value) (value (object qobject))
  (#_setValue object value))

(defun qobject-alive-p (object)
  "Returns T if the object is not null and not deleted."
  (not (or (null-qobject-p object)
           (qobject-deleted object))))

(defun maybe-delete-qobject (object)
  "Deletes the object if possible."
  (if (typep object 'abstract-qobject)
      (when (qobject-alive-p object)
        #+:verbose (v:trace :qtools "Deleting QObject: ~a" object)
        (optimized-delete object))
      #+:verbose (v:trace :qtools "Deleting QObject: WARN Tried to delete non-qobject ~a" object)))

(defmacro qtenumcase (keyform &body forms)
  "Just like CASE, but for Qt enums using QT:ENUM=."
  (let ((key (gensym "KEY")))
    `(let ((,key ,keyform))
       (cond ,@(loop for (comp . form) in forms
                     collect (if (or (eql comp T)
                                     (eql comp 'otherwise))
                                 `(T ,@form)
                                 `((qt:enum= ,key ,comp) ,@form)))))))

(defun map-layout (function layout)
  "Map all widgets on LAYOUT onto FUNCTION."
  (loop for i from 0
        for item = (#_itemAt layout i)
        until (typep item 'null-qobject)
        do (funcall function (#_widget item))))

(defmacro do-layout ((widget layout) &body body)
  "Iterate over all WIDGETs on LAYOUT."
  `(map-layout (lambda (,widget) ,@body) ,layout))

(defun clear-layout (layout)
  "Removes all widgets from the layout and finalizes them."
  (loop for item = (#_takeAt layout 0)
        until (typep item 'null-qobject)
        do (#_removeItem layout item)
           (finalize (#_widget item))))

(defun enumerate-method-descriptors (name args)
  "Returns a list of all possible method descriptors with NAME and ARGS.
Args may be either a list of direct types to use or a list of alternative types.
In the case of lists, the argument alternatives are taken in parallel.

Examples: 
 (.. foo '(a b)) => (\"foo(a,b)\")
 (.. foo '((a b))) => (\"foo(a)\" \"foo(b)\")
 (.. foo '((a b) (0 1))) => (\"foo(a,0)\" \"foo(b,1)\")"
  (flet ((make-map (args)
           (format NIL "~a(~{~a~^, ~})" name (mapcar #'to-type-name args))))
    (cond
      ((and args (listp (first args)))
       (loop for i from 0 below (length (first args))
             collect (make-map (mapcar #'(lambda (list) (nth i list)) args))))
      (T
       (list (make-map args))))))

;;;;;
;; General utils

(defun ensure-class (thing)
  "Ensures to return a CLASS.
SYMBOL -> FIND-CLASS
CLASS  -> IDENTITY
STANDARD-OBJECT -> CLASS-OF"
  (etypecase thing
    (symbol (find-class thing))
    (class thing)
    (standard-object (class-of thing))))

(defmacro with-slots-bound ((instance class) &body body)
  "Turns into a WITH-SLOTS with all direct-slots of CLASS.
Class is resolved as per ENSURE-CLASS."
  (let ((slots (loop for slot in (c2mop:class-direct-slots
                                  (let ((class (ensure-class class)))
                                    (c2mop:finalize-inheritance class)
                                    class))
                     for name = (c2mop:slot-definition-name slot)
                     collect name)))
    `(with-slots ,slots ,instance
       (declare (ignorable ,@slots))
       ,@body)))

(defmacro with-all-slots-bound ((instance class) &body body)
  "Turns into a WITH-SLOTS with all slots of CLASS.
Class is resolved as per ENSURE-CLASS."
  (let ((slots (loop for slot in (c2mop:class-slots
                                  (let ((class (ensure-class class)))
                                    (c2mop:finalize-inheritance class)
                                    class))
                     for name = (c2mop:slot-definition-name slot)
                     collect name)))
    `(with-slots ,slots ,instance
       (declare (ignorable ,@slots))
       ,@body)))

(defun fuse-plists (&rest plists-lists)
  (let ((target (make-hash-table)))
    (dolist (plists plists-lists)
      (loop for (option args) on plists by #'cddr
            do (setf (gethash option target)
                     (nconc (gethash option target) args))))
    (loop for key being the hash-keys of target
          for val being the hash-values of target
          appending (list key val))))

(defun fuse-alists (&rest alists-lists)
  (let ((target (make-hash-table)))
    (dolist (alists alists-lists)
      (loop for (option . args) in alists
            do (setf (gethash option target)
                     (append (gethash option target) args))))
    (loop for key being the hash-keys of target
          for val being the hash-values of target
          collect (cons key val))))

(defun split (list items &key (key #'identity) (test #'eql))
  "Segregates items in LIST into separate lists if they mach an item in ITEMS.
The first item in the returned list is the list of unmatched items.

Example:
 (split '((0 a) (0 b) (1 a) (1 b) (2 c)) '(0 2) :key #'car)
 => '(((1 a) (1 b)) ((0 a) (0 b)) ((2 c))) "
  (loop with table = ()
        for item in list
        do (push item (getf table (find (funcall key item) items :test test)))
        finally (return (cons (nreverse (getf table NIL))
                              (loop for item in items
                                    collect (nreverse (getf table item)))))))

(defmacro with-compile-and-run (&body body)
  "Compiles BODY in a lambda and funcalls it."
  `(funcall
    (compile NIL `(lambda () ,,@body))))

(defun maybe-unwrap-quote (thing)
  "If it is a quote form, unwraps the contents. Otherwise returns it directly."
  (if (and (listp thing)
           (eql 'quote (first thing)))
      (second thing)
      thing))

(defun capitalize-on (character string &optional (replacement character) start-capitalized)
  (with-output-to-string (stream)
    (loop with capitalize = start-capitalized
          for char across (string-downcase string)
          do (cond ((char= char character)
                    (setf capitalize T)
                    (when replacement
                      (write-char replacement stream)))
                   (capitalize
                    (write-char (char-upcase char) stream)
                    (setf capitalize NIL))
                   (T
                    (write-char char stream))))))

(define-condition compilation-note (#+:sbcl sb-ext:compiler-note #-:sbcl condition)
  ((message :initarg :message :initform (error "MESSAGE required.") :accessor message))
  (:report (lambda (c s) (write-string (message c) s))))

(defun emit-compilation-note (format-string &rest args)
  (let ((message (apply #'format NIL format-string args)))
    #+:sbcl (sb-c:maybe-compiler-notify 'compilation-note :message message)
    #-:sbcl (signal 'compilation-note :message message)))

(defun ensure-cl-function-name (name)
  (if (and (listp name) (eql (first name) 'cl+qt:setf))
      `(cl:setf ,(second name))
      name))
