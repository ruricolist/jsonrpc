(in-package #:cl-user)
(defpackage #:jsonrpc/class
  (:use #:cl)
  (:import-from #:jsonrpc/mapper
                #:exposable
                #:expose
                #:register-method
                #:clear-methods
                #:dispatch)
  (:import-from #:jsonrpc/transport/interface
                #:transport
                #:transport-connection
                #:transport-threads
                #:start-server
                #:start-client
                #:receive-message-using-transport)
  (:import-from #:jsonrpc/connection
                #:*connection*
                #:set-callback-for-id
                #:add-message-to-outbox)
  (:import-from #:jsonrpc/request-response
                #:make-request
                #:response-error
                #:response-error-code
                #:response-error-message
                #:response-result)
  (:import-from #:jsonrpc/errors
                #:jsonrpc-callback-error)
  (:import-from #:jsonrpc/utils
                #:find-mode-class
                #:make-id
                #:destroy-thread*)
  (:import-from #:bordeaux-threads
                #:*default-special-bindings*)
  (:import-from #:event-emitter
                #:on
                #:emit
                #:event-emitter)
  (:import-from #:alexandria
                #:remove-from-plist)
  (:export #:*default-timeout*
           #:client
           #:server
           #:jsonrpc-transport
           #:expose
           #:register-method
           #:clear-methods
           #:dispatch
           #:server-listen
           #:client-connect
           #:client-disconnect
           #:send-message
           #:receive-message
           #:call-to
           #:call-async-to
           #:notify-to
           #:call
           #:call-async
           #:notify
           #:notify-async
           #:broadcast
           #:multicall-async))
(in-package #:jsonrpc/class)

(defvar *default-timeout* 60)

(defclass jsonrpc (event-emitter exposable)
  ((transport :type (or null transport)
              :initarg :transport
              :initform nil
              :accessor jsonrpc-transport)))

(defun ensure-connected (jsonrpc)
  (check-type jsonrpc jsonrpc)
  (unless (jsonrpc-transport jsonrpc)
    (error "Connection isn't established yet for ~A" jsonrpc)))

(defclass client (jsonrpc) ())

(defclass server (jsonrpc)
  ((client-connections :initform '()
                       :accessor server-client-connections)
   (%lock :initform (bt:make-lock "client-connections-lock"))))

(defun server-listen (server &rest initargs &key mode &allow-other-keys)
  (let* ((class (find-mode-class mode))
         (initargs (remove-from-plist initargs :mode))
         (bt:*default-special-bindings* `((*standard-output* . ,*standard-output*)
                                          (*error-output* . ,*error-output*)) ))
    (unless class
      (error "Unknown mode ~A" mode))
    (let ((transport (apply #'make-instance class
                            :message-callback
                            (lambda (message)
                              (dispatch server message))
                            initargs)))
      (setf (jsonrpc-transport server) transport)

      (on :open transport
          (lambda (connection)
            (with-slots (%lock client-connections) server
              (on :close connection
                  (lambda ()
                    (bt:with-lock-held (%lock)
                      (setf client-connections
                            (delete connection client-connections)))))
              (bt:with-lock-held (%lock)
                (push connection client-connections)))
            (emit :open server connection)))

      (start-server transport)))
  server)

(defun client-connect (client &rest initargs &key mode &allow-other-keys)
  (let* ((class (find-mode-class mode))
         (initargs (remove-from-plist initargs :mode))
         (bt:*default-special-bindings* `((*standard-output* . ,*standard-output*)
                                          (*error-output* . ,*error-output*)) ))
    (unless class
      (error "Unknown mode ~A" mode))
    (let ((transport (apply #'make-instance class
                            :message-callback
                            (lambda (message)
                              (dispatch client message))
                            initargs)))
      (setf (jsonrpc-transport client) transport)

      (on :open transport
          (lambda (connection)
            (emit :open client connection)))

      (start-client transport)))
  client)

(defun client-disconnect (client)
  (ensure-connected client)
  (let ((transport (jsonrpc-transport client)))
    (mapc #'destroy-thread* (transport-threads transport))
    (setf (transport-threads transport) '())
    (setf (transport-connection transport) nil))
  (emit :close client)
  (values))

(defgeneric send-message (to connection message)
  (:method (to connection message)
    (declare (ignore to))
    (add-message-to-outbox connection message)))

(defun receive-message (from connection)
  (ensure-connected from)
  (receive-message-using-transport (jsonrpc-transport from) connection))

(deftype jsonrpc-params () '(or list array hash-table structure-object standard-object condition))

(defun call-async-to (from to method &optional params callback error-callback)
  (check-type params jsonrpc-params)
  (let ((id (make-id)))
    (set-callback-for-id to
                         id
                         (lambda (response)
                           (if (response-error response)
                               (and error-callback
                                    (funcall error-callback
                                             (response-error-message response)
                                             (response-error-code response)))
                               (and callback
                                    (funcall callback (response-result response))))))

    (send-message from
                  to
                  (make-request :id id
                                :method method
                                :params params))

    (values)))

(defvar *call-to-result* (make-hash-table :test 'eq))
(defvar *call-to-error* (make-hash-table :test 'eq))

(defun hash-exists-p (hash-table key)
  (nth-value 1 (gethash key hash-table)))

(defun call-to (from to method &optional params &rest options)
  (destructuring-bind (&key (timeout *default-timeout*)) options
    (let ((condvar (bt:make-condition-variable))
          (condlock (bt:make-lock))
          (readylock (bt:make-lock)))
      (bt:acquire-lock readylock)
      (call-async-to from to
                     method
                     params
                     (lambda (res)
                       (bt:with-lock-held (readylock)
                         (bt:with-lock-held (condlock)
                           (setf (gethash readylock *call-to-result*) res)
                           (bt:condition-notify condvar))))
                     (lambda (message code)
                       (bt:with-lock-held (readylock)
                         (bt:with-lock-held (condlock)
                           (setf (gethash readylock *call-to-error*)
                                 (make-condition 'jsonrpc-callback-error
                                                 :message message
                                                 :code code))
                           (bt:condition-notify condvar)))))
      (bt:with-lock-held (condlock)
        (bt:release-lock readylock)
        (unless (bt:condition-wait condvar condlock :timeout timeout)
          (error "JSON-RPC synchronous call has been timeout")))

      ;; XXX: Strangely enough, there's sometimes no results/errors here on SBCL.
      #+(and sbcl linux)
      (loop repeat 5
            until (or (hash-exists-p *call-to-result* readylock)
                      (hash-exists-p *call-to-error* readylock))
            do (sleep 0.1))

      (multiple-value-bind (error error-exists-p)
          (gethash readylock *call-to-error*)
        (multiple-value-bind (result result-exists-p)
            (gethash readylock *call-to-result*)
          (assert (or error-exists-p
                      result-exists-p))
          (remhash readylock *call-to-error*)
          (remhash readylock *call-to-result*)
          (if error
              (error error)
              result))))))

(defun notify-to (from to method &optional params)
  (check-type params jsonrpc-params)
  (send-message from
                to
                (make-request :method method
                              :params params)))

(defgeneric call (jsonrpc method &optional params &rest options)
  (:method ((client client) method &optional params &rest options)
    (ensure-connected client)
    (apply #'call-to client (transport-connection (jsonrpc-transport client))
           method params options)))

(defgeneric call-async (jsonrpc method &optional params callback error-callback)
  (:method ((client client) method &optional params callback error-callback)
    (ensure-connected client)
    (call-async-to client (transport-connection (jsonrpc-transport client))
                   method params
                   callback
                   error-callback))
  (:method ((server server) method &optional params callback error-callback)
    (unless (boundp '*connection*)
      (error "`call' is called outside of handlers."))
    (call-async-to server *connection* method params callback error-callback)))

(defgeneric notify (jsonrpc method &optional params)
  (:method ((client client) method &optional params)
    (ensure-connected client)
    (notify-to client (transport-connection (jsonrpc-transport client))
               method params))
  (:method ((server server) method &optional params)
    (unless (boundp '*connection*)
      (error "`notify' is called outside of handlers."))
    (notify-to server *connection*
               method params)))

(defgeneric notify-async (jsonrpc method &optional params)
  (:method ((client client) method &optional params)
    (ensure-connected client)
    (let ((connection (transport-connection (jsonrpc-transport client))))
      (send-message client connection
                    (make-request :method method
                                  :params params))))
  (:method ((server server) method &optional params)
    (unless (boundp '*connection*)
      (error "`notify-async' is called outside of handlers."))
    (send-message server *connection*
                  (make-request :method method
                                :params params))))

;; Experimental
(defgeneric broadcast (jsonrpc method &optional params)
  (:method ((server server) method &optional params)
    (dolist (conn (server-client-connections server))
      (notify server conn method params))))

;; Experimental
(defgeneric multicall-async (jsonrpc method &optional params callback error-callback)
  (:method ((server server) method &optional params callback error-callback)
    (dolist (conn (server-client-connections server))
      (call-async-to server conn method params
                     callback
                     error-callback))))
