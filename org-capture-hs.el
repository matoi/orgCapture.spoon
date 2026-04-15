;;; org-capture-hs.el --- Hammerspoon-driven org-capture  -*- lexical-binding: t; -*-

;; Author: Noriaki Matoi
;; Keywords: hammerspoon, org-capture, macos

;;; Commentary:

;; Generic integration between Hammerspoon and org-capture.
;; Receives context from Hammerspoon (source app, URI, clipboard state)
;; and runs org-capture with a temporary single-entry template.
;;
;; The generic layer handles:
;; - Context reception and buffer-local storage
;; - Frame management for dedicated capture frames
;; - Hammerspoon notification on finalize/cancel
;;
;; Local customization is injected via:
;; - `org-capture-hs-template-function'  (template string builder)
;; - `org-capture-hs-target-function'    (capture target builder)
;; - `org-capture-hs-cleanup-function'   (pre-finalize cleanup)

;;; Code:

(require 'org-capture)

;;;; Customization

(defgroup org-capture-hs nil
  "Org capture integration with Hammerspoon."
  :group 'org
  :group 'external)

(defcustom org-capture-hs-template-function #'org-capture-hs-default-template
  "Function to build a capture template string from context.
Called with one argument, the context plist.
Should return an org-capture template string."
  :type 'function
  :group 'org-capture-hs)

(defcustom org-capture-hs-target-function #'org-capture-hs-default-target
  "Function to determine the capture target from context.
Called with one argument, the context plist.
Should return an org-capture target specification."
  :type 'function
  :group 'org-capture-hs)

(defcustom org-capture-hs-cleanup-function nil
  "Function called before capture finalize.
Called with one argument, the context plist.
Runs while the capture buffer is still alive."
  :type '(choice (const :tag "None" nil) function)
  :group 'org-capture-hs)

(defcustom org-capture-hs-display 'dedicated-frame
  "How to display the capture buffer.
`current-frame' reuses the selected frame.
`dedicated-frame' creates a new frame for the capture."
  :type '(choice (const :tag "Current frame" current-frame)
                 (const :tag "Dedicated frame" dedicated-frame))
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-title "org-capture"
  "Title for dedicated capture frames."
  :type 'string
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-width 80
  "Width of dedicated capture frames."
  :type '(choice (const :tag "Default" nil) integer)
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-height 40
  "Height of dedicated capture frames."
  :type '(choice (const :tag "Default" nil) integer)
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-left nil
  "Left position of dedicated capture frames."
  :type '(choice (const :tag "Default" nil) integer)
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-top nil
  "Top position of dedicated capture frames."
  :type '(choice (const :tag "Default" nil) integer)
  :group 'org-capture-hs)

(defcustom org-capture-hs-frame-parameters nil
  "Additional frame parameters for dedicated capture frames."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'org-capture-hs)

(defcustom org-capture-hs-screenshot-subdir "images"
  "Subdirectory name for screenshots, relative to the capture target file."
  :type 'string
  :group 'org-capture-hs)

;;;; Buffer-local state

(defvar-local org-capture-hs--context nil
  "Buffer-local capture context plist.
Set in the capture buffer by `org-capture-mode-hook'.")

;;;; Internal state for finalize/destroy handoff

(defvar org-capture-hs--pending-context nil
  "Context awaiting transfer to the capture buffer via hook.")

(defvar org-capture-hs--saved-context nil
  "Context saved before finalize/destroy for use in after-hooks.")

(defvar org-capture-hs--saved-frame nil
  "Frame saved before finalize/destroy for cleanup.")

;;;; Hammerspoon communication

(defun org-capture-hs--hammerspoon-do (command)
  "Send COMMAND to Hammerspoon via the hs CLI."
  (let ((hs-binary (executable-find "hs")))
    (if hs-binary
        (call-process hs-binary nil 0 nil "-c" command)
      (message "org-capture-hs: hs executable not found"))))

(defun org-capture-hs--lua-quote (str)
  "Quote STR as a Lua string literal.  Return \"nil\" if STR is nil."
  (if str
      (concat "\""
              (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" str)
              "\"")
    "nil"))

(defun org-capture-hs--notify-return (context)
  "Tell Hammerspoon to return focus to the source window/app."
  (let ((window-id (or (plist-get context :window-id) 0))
        (bundle-id (plist-get context :bundle-id))
        (app-name (plist-get context :app-name)))
    (org-capture-hs--hammerspoon-do
     (format "spoon.orgCapture:returnToSource(%d, %s, %s)"
             window-id
             (org-capture-hs--lua-quote bundle-id)
             (org-capture-hs--lua-quote app-name)))))

;;;; Template helpers

(defun org-capture-hs-escape-percent (str)
  "Escape percent signs in STR for use in org-capture templates."
  (if str
      (replace-regexp-in-string "%" "%%" str)
    ""))

;;;; Screenshot placement

(defun org-capture-hs--place-screenshot (tmp-path target)
  "Move screenshot from TMP-PATH to a subdirectory alongside TARGET org file.
TARGET is an org-capture target specification like (file \"/path/to/file.org\").
Returns the final absolute path of the screenshot, or nil on failure."
  (when (and tmp-path (file-exists-p tmp-path))
    (let* ((target-file (pcase (car target)
                          ('file (nth 1 target))
                          (_ org-default-notes-file)))
           (target-dir (file-name-directory (expand-file-name target-file)))
           (img-dir (expand-file-name org-capture-hs-screenshot-subdir target-dir))
           (filename (file-name-nondirectory tmp-path))
           (dest (expand-file-name filename img-dir)))
      (make-directory img-dir t)
      (rename-file tmp-path dest t)
      dest)))

(defun org-capture-hs--screenshot-relative-path (screenshot-path target)
  "Return the path of SCREENSHOT-PATH relative to the TARGET org file directory."
  (when screenshot-path
    (let* ((target-file (pcase (car target)
                          ('file (nth 1 target))
                          (_ org-default-notes-file)))
           (target-dir (file-name-directory (expand-file-name target-file))))
      (file-relative-name screenshot-path target-dir))))

;;;; Default template and target

(defun org-capture-hs--make-org-link (uri title)
  "Create an org-mode link from URI and TITLE.
Return TITLE if URI is nil or empty."
  (if (and uri (not (string-empty-p uri)))
      (let ((safe-title (or title uri)))
        (format "[[%s][%s]]"
                uri
                (replace-regexp-in-string
                 "\\[\\|\\]"
                 (lambda (s) (if (string= s "[") "{" "}"))
                 safe-title)))
    (or title "")))

(defun org-capture-hs-default-template (context)
  "Build a default capture template with org link when URI is available.
Screenshot is included as an inline file link.  OCR text is not
inserted automatically; use `org-capture-hs-run-ocr' in the capture
buffer to insert it on demand."
  (let* ((uri (plist-get context :uri))
         (title (plist-get context :window-title))
         (screenshot-rel (plist-get context :screenshot-rel))
         (heading (org-capture-hs-escape-percent
                   (if uri
                       (org-capture-hs--make-org-link uri title)
                     (or title "capture")))))
    (concat "* " heading "\n"
            (when screenshot-rel
              (concat "[[file:" (org-capture-hs-escape-percent screenshot-rel) "]]\n"))
            "%?\n")))

(defun org-capture-hs-default-target (_context)
  "Default capture target: `org-default-notes-file'."
  `(file ,org-default-notes-file))

;;;; Frame management

(defun org-capture-hs--frame-parameters ()
  "Build frame parameters for a dedicated capture frame."
  (append
   (delq nil
         `((org-capture-hs-frame . t)
           (minibuffer . t)
           (name . ,org-capture-hs-frame-title)
           ,(and org-capture-hs-frame-width
                 `(width . ,org-capture-hs-frame-width))
           ,(and org-capture-hs-frame-height
                 `(height . ,org-capture-hs-frame-height))
           ,(and org-capture-hs-frame-left
                 `(left . ,org-capture-hs-frame-left))
           ,(and org-capture-hs-frame-top
                 `(top . ,org-capture-hs-frame-top))))
   org-capture-hs-frame-parameters))

(defun org-capture-hs--make-frame ()
  "Create and select a dedicated capture frame."
  (let ((frame (make-frame (org-capture-hs--frame-parameters))))
    (select-frame-set-input-focus frame)
    frame))

;;;; Capture mode hook

(defun org-capture-hs--setup-capture-buffer ()
  "Transfer pending context to buffer-local storage in capture buffer."
  (when org-capture-hs--pending-context
    (setq-local org-capture-hs--context org-capture-hs--pending-context)
    (setq org-capture-hs--pending-context nil)))

(add-hook 'org-capture-mode-hook #'org-capture-hs--setup-capture-buffer)

;;;; Screenshot cleanup on cancel

(defun org-capture-hs--delete-screenshot (context)
  "Delete the screenshot file associated with CONTEXT."
  (let ((path (plist-get context :screenshot-path)))
    (message "org-capture-hs: delete-screenshot path=%s" path)
    (when (and path (file-exists-p path))
      (delete-file path)
      (message "org-capture-hs: deleted screenshot %s" path))))

;;;; OCR command

(defcustom org-capture-hs-ocr-languages '("ja" "en")
  "Languages for OCR recognition, passed to the Swift Vision framework."
  :type '(repeat string)
  :group 'org-capture-hs)

(defun org-capture-hs--ocr-script-path ()
  "Return the path to the OCR Swift script."
  (expand-file-name "ocr-screenshot.swift"
                    (file-name-directory (locate-library "org-capture-hs"))))

(defun org-capture-hs-run-ocr ()
  "Run OCR on the screenshot associated with the current capture buffer.
Insert the recognized text at point in a quote block."
  (interactive)
  (unless org-capture-hs--context
    (user-error "Not in a Hammerspoon capture buffer"))
  (let ((path (plist-get org-capture-hs--context :screenshot-path)))
    (unless (and path (file-exists-p path))
      (user-error "No screenshot file found"))
    (let* ((script (org-capture-hs--ocr-script-path))
           (output (with-output-to-string
                     (with-current-buffer standard-output
                       (call-process "swift" nil t nil script path)))))
      (setq output (string-trim output))
      (if (string-empty-p output)
          (message "OCR: no text recognized")
        (insert "#+begin_quote\n" output "\n#+end_quote\n")))))

;;;; Finalize / destroy hooks

(defun org-capture-hs--before-finalize ()
  "Save context and run cleanup before the capture buffer is killed."
  (when org-capture-hs--context
    (setq org-capture-hs--saved-context org-capture-hs--context)
    (setq org-capture-hs--saved-frame
          (when (frame-parameter nil 'org-capture-hs-frame)
            (selected-frame)))
    (when (functionp org-capture-hs-cleanup-function)
      (funcall org-capture-hs-cleanup-function org-capture-hs--context))))

(defun org-capture-hs--after-finalize ()
  "Close frame and notify Hammerspoon after finalize."
  (when org-capture-hs--saved-context
    (let ((context org-capture-hs--saved-context)
          (frame org-capture-hs--saved-frame))
      (setq org-capture-hs--saved-context nil)
      (setq org-capture-hs--saved-frame nil)
      (when (frame-live-p frame)
        (delete-frame frame))
      (org-capture-hs--notify-return context))))

(add-hook 'org-capture-before-finalize-hook #'org-capture-hs--before-finalize)
(add-hook 'org-capture-after-finalize-hook #'org-capture-hs--after-finalize)

(defun org-capture-hs--around-destroy (orig-fn &rest args)
  "Save context before destroy, then clean up frame and notify Hammerspoon.
Also deletes the associated screenshot file."
  (let ((context org-capture-hs--context)
        (frame (when (frame-parameter nil 'org-capture-hs-frame)
                 (selected-frame))))
    (apply orig-fn args)
    (when context
      (org-capture-hs--delete-screenshot context)
      (when (frame-live-p frame)
        (delete-frame frame))
      (org-capture-hs--notify-return context))))

(advice-add 'org-capture-destroy :around #'org-capture-hs--around-destroy)

(defun org-capture-hs--around-kill (orig-fn &rest args)
  "Save context before kill, then clean up frame and notify Hammerspoon.
`org-capture-kill' does not go through `org-capture-destroy' or the
finalize hooks, so we need separate advice here.
Also deletes the associated screenshot file."
  (let ((context org-capture-hs--context)
        (frame (when (frame-parameter nil 'org-capture-hs-frame)
                 (selected-frame))))
    (apply orig-fn args)
    (when context
      (org-capture-hs--delete-screenshot context)
      (when (frame-live-p frame)
        (delete-frame frame))
      (org-capture-hs--notify-return context))))

(advice-add 'org-capture-kill :around #'org-capture-hs--around-kill)

;;;; Main entry point

;;;###autoload
(defun org-capture-hs-begin (app-name bundle-id window-id window-title
                                      &optional uri use-clipboard
                                      screenshot-path)
  "Begin org-capture with context from Hammerspoon.

APP-NAME is the source application name.
BUNDLE-ID is the source application bundle identifier.
WINDOW-ID is the numeric window identifier.
WINDOW-TITLE is the source window title.
URI is an optional URL or file path from the source.
USE-CLIPBOARD indicates whether the clipboard contains relevant content.
SCREENSHOT-PATH is an optional path to a screenshot temp file."
  (let* ((clean-uri (unless (or (null uri) (equal uri "")) uri))
         (clean-screenshot (unless (or (null screenshot-path)
                                       (equal screenshot-path ""))
                             screenshot-path))
         (context (list :app-name app-name
                        :bundle-id bundle-id
                        :window-id window-id
                        :window-title window-title
                        :uri clean-uri
                        :use-clipboard use-clipboard
                        :screenshot-path clean-screenshot))
         (target (funcall (or org-capture-hs-target-function
                              #'org-capture-hs-default-target)
                          context))
         ;; Place screenshot and add relative/absolute paths to context
         (final-screenshot (when clean-screenshot
                             (org-capture-hs--place-screenshot
                              clean-screenshot target)))
         (screenshot-rel (when final-screenshot
                           (org-capture-hs--screenshot-relative-path
                            final-screenshot target)))
         (context (if final-screenshot
                      (plist-put (plist-put context :screenshot-path final-screenshot)
                                 :screenshot-rel screenshot-rel)
                    context))
         (template-str (funcall (or org-capture-hs-template-function
                                    #'org-capture-hs-default-template)
                                context))
         (display-buffer-alist
          '(("^CAPTURE-"
             (display-buffer-same-window)
             (inhibit-same-window . nil))))
         (org-capture-templates
          `(("H" "Hammerspoon capture"
             entry ,target ,template-str
             :empty-lines 1
             :no-save t))))
    (setq org-capture-hs--pending-context context)
    (when (eq org-capture-hs-display 'dedicated-frame)
      (org-capture-hs--make-frame)
      (delete-other-windows))
    (org-capture nil "H")))

(provide 'org-capture-hs)

;;; org-capture-hs.el ends here
