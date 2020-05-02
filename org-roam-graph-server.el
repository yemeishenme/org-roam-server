;;; org-roam-graph-server.el --- Org Roam Database Visualizer -*- lexical-binding: t; -*-

;; Author: Göktuğ Karakaşlı <karakasligk@gmail.com>
;; URL: https://github.com/goktug97/org-roam-graph-server
;; Version: 1.0.0
;; Package-Requires: ((org-roam "1.1.1") (org "9.3") (emacs "26.1") (simple-httpd "1.5.1"))

;; MIT License

;; Copyright (c) 2020 Göktuğ Karakaşlı

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:
;; A web application to visualize the org-roam database in an interactive graph.
;; Use M-x org-roam-graph-server-mode RET to enable the global mode.
;; It will start a web server on http://127.0.0.1:8080

(require 'simple-httpd)
(require 'json)

(require 'ox)
(require 'ox-html)

(require 'org-roam)
(require 'org-roam-graph)
(require 'org-roam-buffer)

;;; Code:

(defvar org-roam-graph-server-current-buffer (window-buffer))
(defun org-roam-graph-server-update-current-buffer ()
  "Save the current buffer in a variable to publish to server."
  (setq org-roam-graph-server-current-buffer
        (window-buffer)))

(defvar org-roam-graph-server-root (concat (file-name-directory (or load-file-name buffer-file-name)) "."))
(setq httpd-root org-roam-graph-server-root)

(defun org-roam-graph-server-html-servlet (file)
  "Export the FILE to HTML and create a servlet for it."
  `(defservlet ,(intern (concat (org-roam--path-to-slug file) ".html")) text/html (path)
     (let ((html-string))
       (with-temp-buffer
         (setq-local
          org-html-style-default
          (format "<style>%s</style>"
                  (with-temp-buffer
                    (insert-file-contents
                     (concat org-roam-graph-server-root
                             "/assets/org.css"))
                    (buffer-string))))
         (insert-file-contents ,file)
         (setq html-string (org-export-as 'html)))
       (insert html-string))))

(defun org-roam-graph-server-visjs-json (node-query)
  "Convert `org-roam` db to visjs json format."
  (org-roam-db--ensure-built)
  (org-roam--with-temp-buffer
    (let* ((nodes (org-roam-db-query node-query))
           (edges-query
            `[:with selected :as [:select [file] :from ,node-query]
                    :select :distinct [to from] :from links
                    :where (and (in to selected) (in from selected))])
           (edges-cites-query
            `[:with selected :as [:select [file] :from ,node-query]
                    :select :distinct [file from] :from links
                    :inner :join refs :on (and (= links:to refs:ref)
                                               (= links:type "cite"))
                    :where (and (in file selected) (in from selected))])
           (edges       (org-roam-db-query edges-query))
           (edges-cites (org-roam-db-query edges-cites-query))
           (graph (list (cons 'nodes (list))
                        (cons 'edges (list)))))
      (dotimes (idx (length nodes))
        (let* ((file (xml-escape-string (car (elt nodes idx))))
               (title (or (caadr (elt nodes idx))
                          (org-roam--path-to-slug file))))
          (push (list (cons 'id (org-roam--path-to-slug file))
                      (cons 'label (xml-escape-string title))
                      (cons 'url (concat "org-protocol://roam-file?file="
                                         (url-hexify-string file))))
                (cdr (elt graph 0)))))
      (dolist (edge edges)
        (let* ((title-source (org-roam--path-to-slug (elt edge 0)))
               (title-target (org-roam--path-to-slug (elt edge 1))))
          (push (list (cons 'from title-source)
                      (cons 'to title-target)
                      ;(cons 'arrows "to")
                      )
                (cdr (elt graph 1)))))
      (dolist (edge edges-cites)
        (let* ((title-source (org-roam--path-to-slug (elt edge 0)))
               (title-target (org-roam--path-to-slug (elt edge 1))))
          (push (list (cons 'from title-source)
                      (cons 'to title-target)
                      ;(cons 'arrows "to")
                      )
                (cdr (elt graph 1)))))
      (json-encode graph))))

;;;###autoload
(define-minor-mode org-roam-graph-server-mode
  "Start the http server and serve org-roam files."
  :lighter ""
  :global t
  :init-value nil
  (cond
   (org-roam-graph-server-mode
    (add-hook 'post-command-hook #'org-roam-graph-server-find-file-hook-function)
    (httpd-start)
    (let ((node-query `[:select [file titles] :from titles
                                ,@(org-roam-graph--expand-matcher 'file t)]))
      (org-roam--with-temp-buffer
        (let ((nodes (org-roam-db-query node-query)))
          (dotimes (idx (length nodes))
            (let ((file (xml-escape-string (car (elt nodes idx)))))
              (if (org-roam--org-roam-file-p file)
                  (eval (org-roam-graph-server-html-servlet file)))))))))
   (t
    (remove-hook 'post-command-hook #'org-roam-graph-server-find-file-hook-function t)
    (dolist (buf (org-roam--get-roam-buffers))
      (with-current-buffer buf
        (remove-hook 'post-command-hook #'org-roam-graph-server-update-current-buffer t)))
    (httpd-stop))))

(defun org-roam-graph-server-find-file-hook-function ()
  "If a file is an `org-roam` file, update the current buffer."
  (when (org-roam--org-roam-file-p)
    (setq org-roam-last-window (get-buffer-window))
    (add-hook 'post-command-hook #'org-roam-graph-server-update-current-buffer nil t)
    (org-roam-graph-server-update-current-buffer)))

(defservlet current-roam-buffer text/event-stream (path)
  (insert (format "data:%s\n\n"
                  (if (org-roam--org-roam-file-p
                       (buffer-file-name org-roam-graph-server-current-buffer))
                      (car (last
                            (split-string
                             (org-roam--path-to-slug
                              (buffer-name org-roam-graph-server-current-buffer))
                             "/")))
                    ""))))

(defservlet graph-data text/event-stream (path)
  (let* ((node-query `[:select [file titles]
                               :from titles
                               ,@(org-roam-graph--expand-matcher 'file t)]))
    (insert (format "data:%s\n\n" (org-roam-graph-server-visjs-json node-query)))))

(provide 'org-roam-graph-server)

;;; org-roam-graph-server.el ends here
