;;; test-org-capture-hs.el --- Tests for org-capture-hs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -l test-org-capture-hs.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org-capture-hs)

;;; --- org-capture-hs-escape-percent ---

(ert-deftest test-escape-percent/no-percent ()
  "Plain string passes through unchanged."
  (should (equal "hello world" (org-capture-hs-escape-percent "hello world"))))

(ert-deftest test-escape-percent/single-percent ()
  "Single % is doubled."
  (should (equal "100%% done" (org-capture-hs-escape-percent "100% done"))))

(ert-deftest test-escape-percent/url-encoded ()
  "URL-encoded %20 etc. are escaped for org-capture."
  (should (equal "https://example.com/a%%20b"
                 (org-capture-hs-escape-percent "https://example.com/a%20b"))))

(ert-deftest test-escape-percent/multiple-percents ()
  "Multiple %'s are all doubled."
  (should (equal "%%a%%b%%c"
                 (org-capture-hs-escape-percent "%a%b%c"))))

(ert-deftest test-escape-percent/nil ()
  "nil returns empty string."
  (should (equal "" (org-capture-hs-escape-percent nil))))

(ert-deftest test-escape-percent/org-capture-sequences ()
  "Org-capture special sequences like %U, %? are escaped."
  (should (equal "%%U %%? %%(func)" (org-capture-hs-escape-percent "%U %? %(func)"))))

;;; --- org-capture-hs--make-org-link ---

(ert-deftest test-make-org-link/basic ()
  "Basic URL and title produce org link."
  (should (equal "[[https://example.com][Example Page]]"
                 (org-capture-hs--make-org-link "https://example.com" "Example Page"))))

(ert-deftest test-make-org-link/nil-uri ()
  "nil URI returns title."
  (should (equal "My Title" (org-capture-hs--make-org-link nil "My Title"))))

(ert-deftest test-make-org-link/empty-uri ()
  "Empty URI returns title."
  (should (equal "My Title" (org-capture-hs--make-org-link "" "My Title"))))

(ert-deftest test-make-org-link/nil-title ()
  "nil title falls back to URI."
  (should (equal "[[https://example.com][https://example.com]]"
                 (org-capture-hs--make-org-link "https://example.com" nil))))

(ert-deftest test-make-org-link/brackets-in-title ()
  "Square brackets in title are replaced with curly brackets."
  (should (equal "[[https://example.com][{title}]]"
                 (org-capture-hs--make-org-link "https://example.com" "[title]"))))

(ert-deftest test-make-org-link/percent-in-url ()
  "Percent in URL is preserved (not doubled here — caller escapes for template)."
  (should (equal "[[https://example.com/a%20b][title]]"
                 (org-capture-hs--make-org-link "https://example.com/a%20b" "title"))))

;;; --- org-capture-hs-default-template ---

(ert-deftest test-default-template/no-uri ()
  "Without URI, heading is the window title."
  (let ((ctx '(:app-name "Safari" :window-title "My Page" :uri nil)))
    (should (equal "* My Page\n%?\n"
                   (org-capture-hs-default-template ctx)))))

(ert-deftest test-default-template/with-uri ()
  "With URI, heading is an org link."
  (let ((ctx '(:app-name "Safari"
               :window-title "Example"
               :uri "https://example.com")))
    (should (equal "* [[https://example.com][Example]]\n%?\n"
                   (org-capture-hs-default-template ctx)))))

(ert-deftest test-default-template/uri-with-percent ()
  "URL containing % is escaped in template (so org-capture doesn't expand it)."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Search"
                :uri "https://example.com/q?a=1%26b=2"))
         (tmpl (org-capture-hs-default-template ctx)))
    ;; The %26 in the URL must become %%26 in the template
    (should (string-match-p "%%26" tmpl))
    ;; Must NOT contain bare %26 (which org-capture would try to expand)
    (should-not (string-match-p "[^%]%26" tmpl))))

(ert-deftest test-default-template/no-format-side-effects ()
  "Template must not corrupt % sequences via format.
A URL like 'https://x.com/%5Epage' must not produce %^L (org-capture link prompt)."
  (let* ((ctx '(:app-name "Arc"
                :window-title "Caret Page"
                :uri "https://x.com/%5Epage"))
         (tmpl (org-capture-hs-default-template ctx)))
    ;; Must contain %%5E (escaped), NOT %^  (which is what %5E decodes to)
    (should (string-match-p "%%5E" tmpl))
    ;; Must NOT contain unescaped %^ (org-capture prompt trigger)
    (should-not (string-match-p "[^%]%\\^" tmpl))))

;;; --- Template is valid for org-capture (no stray format directives) ---

(ert-deftest test-template/concat-not-format ()
  "Template built with concat preserves %% escaping.
If format were used, %% would collapse to % and corrupt the template."
  (let* ((ctx '(:app-name "Test"
                :window-title "100% Complete"
                :uri nil))
         (tmpl (org-capture-hs-default-template ctx)))
    ;; The % in the title must be doubled for org-capture
    (should (equal "* 100%% Complete\n%?\n" tmpl))))

;;; --- org-capture-hs--lua-quote ---

(ert-deftest test-lua-quote/basic ()
  "Basic string is quoted."
  (should (equal "\"hello\"" (org-capture-hs--lua-quote "hello"))))

(ert-deftest test-lua-quote/nil ()
  "nil returns Lua nil."
  (should (equal "nil" (org-capture-hs--lua-quote nil))))

(ert-deftest test-lua-quote/escapes ()
  "Backslash and double-quote are escaped."
  (should (equal "\"a\\\"b\\\\c\"" (org-capture-hs--lua-quote "a\"b\\c"))))

(ert-deftest test-lua-quote/injection ()
  "Lua injection via closing quote is escaped."
  (let ((malicious "x\" .. os.execute(\"id\") .. \"y"))
    ;; The result must be a single quoted Lua string with all " escaped
    (let ((result (org-capture-hs--lua-quote malicious)))
      ;; Must start and end with unescaped "
      (should (string-prefix-p "\"" result))
      (should (string-suffix-p "\"" result))
      ;; Interior must not contain unescaped "
      (let ((interior (substring result 1 -1)))
        (should-not (string-match-p "[^\\\\]\"" interior))))))

;;; --- Context construction in org-capture-hs-begin ---

;; We can't fully call org-capture-hs-begin without a running Emacs frame,
;; but we can test that the context plist is built correctly.

(ert-deftest test-context/uri-nil-when-empty-string ()
  "Empty-string URI should become nil in context."
  ;; Simulate the (unless ...) logic from org-capture-hs-begin
  (let ((uri ""))
    (should (null (unless (or (null uri) (equal uri "")) uri)))))

(ert-deftest test-context/uri-preserved-when-present ()
  "Non-empty URI is preserved."
  (let ((uri "https://example.com"))
    (should (equal "https://example.com"
                   (unless (or (null uri) (equal uri "")) uri)))))

(ert-deftest test-context/uri-nil-when-nil ()
  "nil URI stays nil."
  (let ((uri nil))
    (should (null (unless (or (null uri) (equal uri "")) uri)))))

;;; --- org-capture-hs--screenshot-relative-path ---

(ert-deftest test-screenshot-relative-path/basic ()
  "Relative path from org dir to screenshot in images subdir."
  (should (equal "images/shot.png"
                 (org-capture-hs--screenshot-relative-path
                  "/home/user/org/images/shot.png"
                  '(file "/home/user/org/notes.org")))))

(ert-deftest test-screenshot-relative-path/nil ()
  "nil screenshot path returns nil."
  (should (null (org-capture-hs--screenshot-relative-path
                 nil '(file "/home/user/org/notes.org")))))

(ert-deftest test-screenshot-relative-path/nested-target ()
  "Relative path works with nested org file directories."
  (should (equal "images/shot.png"
                 (org-capture-hs--screenshot-relative-path
                  "/home/user/org/daily/images/shot.png"
                  '(file "/home/user/org/daily/2026-04-15.org")))))

(ert-deftest test-screenshot-relative-path/fallback-default-notes-file ()
  "Non-file target falls back to `org-default-notes-file'."
  (let ((org-default-notes-file "/home/user/org/notes.org"))
    (should (equal "images/shot.png"
                   (org-capture-hs--screenshot-relative-path
                    "/home/user/org/images/shot.png"
                    '(clock))))))

;;; --- org-capture-hs--place-screenshot ---

(ert-deftest test-place-screenshot/moves-file ()
  "Screenshot is moved from tmp to images subdir alongside target."
  (let* ((tmp-dir (make-temp-file "hs-test" t))
         (org-dir (make-temp-file "hs-org" t))
         (tmp-png (expand-file-name "orgcapture-test.png" tmp-dir))
         (org-file (expand-file-name "notes.org" org-dir))
         (org-capture-hs-screenshot-subdir "images"))
    (unwind-protect
        (progn
          (with-temp-file tmp-png (insert "fake png"))
          (let ((result (org-capture-hs--place-screenshot
                         tmp-png `(file ,org-file))))
            ;; Returns the final path
            (should result)
            (should (string-match-p "/images/orgcapture-test\\.png$" result))
            ;; File exists at destination
            (should (file-exists-p result))
            ;; File removed from tmp
            (should-not (file-exists-p tmp-png))))
      (delete-directory tmp-dir t)
      (delete-directory org-dir t))))

(ert-deftest test-place-screenshot/nil-path ()
  "nil tmp-path returns nil without error."
  (should (null (org-capture-hs--place-screenshot
                 nil '(file "/tmp/notes.org")))))

(ert-deftest test-place-screenshot/nonexistent-file ()
  "Non-existent tmp file returns nil."
  (should (null (org-capture-hs--place-screenshot
                 "/tmp/no-such-file-12345.png"
                 '(file "/tmp/notes.org")))))

;;; --- org-capture-hs-default-template with screenshot/OCR ---

(ert-deftest test-default-template/with-screenshot ()
  "Template includes inline file link when screenshot-rel is present."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Page"
                :uri nil
                :screenshot-rel "images/shot.png"))
         (tmpl (org-capture-hs-default-template ctx)))
    (should (string-match-p "\\[\\[file:images/shot\\.png\\]\\]" tmpl))))

(ert-deftest test-default-template/no-screenshot ()
  "Template without screenshot matches original behavior."
  (let* ((ctx '(:app-name "Safari" :window-title "My Page" :uri nil))
         (tmpl (org-capture-hs-default-template ctx)))
    (should (equal "* My Page\n%?\n" tmpl))))

(ert-deftest test-default-template/screenshot-with-percent ()
  "Percent in screenshot path is escaped for org-capture."
  (let* ((ctx '(:app-name "Test"
                :window-title "Page"
                :uri nil
                :screenshot-rel "images/100%25done.png"))
         (tmpl (org-capture-hs-default-template ctx)))
    ;; % in path must be doubled
    (should (string-match-p "100%%25done" tmpl))))

(ert-deftest test-default-template/no-ocr-in-template ()
  "OCR text in context is NOT automatically included in default template."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Page"
                :uri nil
                :ocr-text "Should not appear"))
         (tmpl (org-capture-hs-default-template ctx)))
    (should-not (string-match-p "Should not appear" tmpl))
    (should-not (string-match-p "begin_quote" tmpl))))

;;; --- local/org-capture-hs-template (simulated from init-local-org.el) ---
;;
;; We define a local copy here to test the concat-based template builder
;; without loading the full init-local-org.el and its dependencies.

(defun test--make-safe-link (url title)
  "Simplified org-link builder matching local/org-create-safe-link."
  (if (and url (stringp url) (not (string-empty-p url)))
      (let ((safe-title (or title url)))
        (format "[[%s][%s]]"
                url
                (replace-regexp-in-string
                 "\\[\\|\\]"
                 (lambda (s) (if (string= s "[") "{" "}"))
                 safe-title)))
    (or title "")))

(defun test--local-template (context)
  "Reproduces local/org-capture-hs-template using concat (not format)."
  (let* ((app-name (plist-get context :app-name))
         (title (plist-get context :window-title))
         (uri (plist-get context :uri))
         (use-clipboard (plist-get context :use-clipboard))
         (screenshot-rel (plist-get context :screenshot-rel))
         (tag (if app-name
                  (replace-regexp-in-string "\\s-" "" (downcase app-name))
                "app"))
         (heading (org-capture-hs-escape-percent
                   (if uri
                       (test--make-safe-link uri title)
                     (or title app-name "capture"))))
         (clipboard-contents
          (if use-clipboard
              (org-capture-hs-escape-percent "quoted text")
            "")))
    (concat
     "* " heading " :" tag ":note:\n"
     ":PROPERTIES:\n"
     ":ID:       %(org-id-new)\n"
     ":CREATED:  %U\n"
     ":END:\n\n"
     (when screenshot-rel
       (concat "[[file:"
               (org-capture-hs-escape-percent screenshot-rel)
               "]]\n\n"))
     clipboard-contents
     "%?\n")))

(ert-deftest test-local-template/no-uri ()
  "Local template with no URI uses window-title as heading."
  (let* ((ctx '(:app-name "Ghostty" :window-title "~/bin/org" :uri nil))
         (tmpl (test--local-template ctx)))
    (should (string-prefix-p "* ~/bin/org :ghostty:note:" tmpl))
    ;; Contains org-capture sequences for org to expand
    (should (string-match-p "%(org-id-new)" tmpl))
    (should (string-match-p "%U" tmpl))
    (should (string-match-p "%\\?" tmpl))))

(ert-deftest test-local-template/with-uri ()
  "Local template with URI produces org link heading."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Example Page"
                :uri "https://example.com"))
         (tmpl (test--local-template ctx)))
    ;; Heading must be an org link
    (should (string-match-p "\\[\\[https://example\\.com\\]\\[Example Page\\]\\]"
                            tmpl))
    ;; Tag derived from app name
    (should (string-match-p ":safari:note:" tmpl))))

(ert-deftest test-local-template/uri-with-percent-encoding ()
  "URL with % encoding is safely escaped in the template."
  (let* ((ctx '(:app-name "Arc"
                :window-title "Search Results"
                :uri "https://example.com/search?q=hello%20world"))
         (tmpl (test--local-template ctx)))
    ;; The %20 in the URL must be escaped to %%20
    (should (string-match-p "%%20" tmpl))
    ;; The template's own %U and %(org-id-new) must NOT be doubled
    (should (string-match-p "[^%]%U" tmpl))
    (should (string-match-p "[^%]%(org-id-new)" tmpl))))

(ert-deftest test-local-template/no-accidental-prompt ()
  "URL containing %5E (^) must not create %^L (link prompt) in template."
  (let* ((ctx '(:app-name "Chrome"
                :window-title "Page"
                :uri "https://example.com/%5Epage"))
         (tmpl (test--local-template ctx)))
    ;; %5E must be %%5E in the template
    (should (string-match-p "%%5E" tmpl))
    ;; No bare %^ which would trigger org-capture prompt
    (should-not (string-match-p "[^%]%\\^" tmpl))))

(ert-deftest test-local-template/brave-browser-tag ()
  "Brave Browser app name becomes 'bravebrowser' tag (spaces removed)."
  (let* ((ctx '(:app-name "Brave Browser"
                :window-title "Page"
                :uri "https://example.com"))
         (tmpl (test--local-template ctx)))
    (should (string-match-p ":bravebrowser:note:" tmpl))))

(ert-deftest test-local-template/clipboard-content ()
  "Clipboard contents are included when use-clipboard is set."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Page"
                :uri nil
                :use-clipboard t))
         (tmpl (test--local-template ctx)))
    (should (string-match-p "quoted text" tmpl))))

(ert-deftest test-local-template/no-clipboard ()
  "No clipboard content when use-clipboard is nil."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Page"
                :uri nil
                :use-clipboard nil))
         (tmpl (test--local-template ctx)))
    (should-not (string-match-p "quoted text" tmpl))))

(ert-deftest test-local-template/with-screenshot ()
  "Local template includes screenshot inline link."
  (let* ((ctx '(:app-name "Safari"
                :window-title "Page"
                :uri nil
                :screenshot-rel "images/shot.png"))
         (tmpl (test--local-template ctx)))
    (should (string-match-p "\\[\\[file:images/shot\\.png\\]\\]" tmpl))
    ;; Screenshot link comes after :END:
    (should (< (string-match ":END:" tmpl)
               (string-match "\\[\\[file:" tmpl)))))

(ert-deftest test-local-template/screenshot-with-percent ()
  "Percent in screenshot path is escaped in local template."
  (let* ((ctx '(:app-name "Test"
                :window-title "Page"
                :uri nil
                :screenshot-rel "images/100%25.png"))
         (tmpl (test--local-template ctx)))
    (should (string-match-p "100%%25" tmpl))))

(ert-deftest test-local-template/screenshot-no-uri ()
  "Screenshot capture without URI uses window title as heading."
  (let* ((ctx '(:app-name "Ghostty"
                :window-title "~/projects"
                :uri nil
                :screenshot-rel "images/shot.png"))
         (tmpl (test--local-template ctx)))
    (should (string-prefix-p "* ~/projects :ghostty:note:" tmpl))
    (should (string-match-p "\\[\\[file:images/shot\\.png\\]\\]" tmpl))))

;;; --- org-capture-hs--delete-screenshot ---

(ert-deftest test-delete-screenshot/deletes-file ()
  "Screenshot file is deleted when context has :screenshot-path."
  (let* ((tmp (make-temp-file "hs-screenshot" nil ".png")))
    (unwind-protect
        (progn
          (should (file-exists-p tmp))
          (org-capture-hs--delete-screenshot `(:screenshot-path ,tmp))
          (should-not (file-exists-p tmp)))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest test-delete-screenshot/nil-path ()
  "nil screenshot-path does nothing."
  (org-capture-hs--delete-screenshot '(:screenshot-path nil))
  ;; No error
  )

(ert-deftest test-delete-screenshot/nonexistent-file ()
  "Non-existent file does nothing."
  (org-capture-hs--delete-screenshot
   '(:screenshot-path "/tmp/no-such-file-99999.png"))
  ;; No error
  )

(provide 'test-org-capture-hs)

;;; test-org-capture-hs.el ends here
