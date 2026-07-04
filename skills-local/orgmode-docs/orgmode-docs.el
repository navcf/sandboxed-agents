;;; orgmode-docs.el --- Self-contained HTML export for shared Org docs -*- lexical-binding: t; -*-

;; Makes `C-c C-e h o' produce a single shareable file: every local image
;; (PNG, SVG, JPEG, ...) referenced by the exported HTML is inlined as a
;; base64 data: URI. Remote (http/https) and already-inline sources are
;; left untouched. Non-HTML backends are unaffected.
;;
;; Doom users: copy the code below into ~/.config/doom/config.el (inside
;; an `after! ox' block), or load this file from there.

(defun orgmode-docs--data-uri (path)
  "Return a data: URI for the image file at PATH, or nil if unsupported."
  (let* ((ext (downcase (or (file-name-extension path) "")))
         (mime (pcase ext
                 ("svg" "image/svg+xml")
                 ("png" "image/png")
                 ((or "jpg" "jpeg") "image/jpeg")
                 ("gif" "image/gif")
                 ("webp" "image/webp")
                 ("avif" "image/avif")
                 (_ nil))))
    (when (and mime (file-readable-p path))
      (concat "data:" mime ";base64,"
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally path)
                (base64-encode-region (point-min) (point-max) t)
                (buffer-string))))))

(defun orgmode-docs-embed-images (output backend _info)
  "Export filter: inline local <img src> files in OUTPUT as data: URIs.
Runs on the final output of HTML-derived BACKENDs only."
  (if (not (org-export-derived-backend-p backend 'html))
      output
    (replace-regexp-in-string
     "<img\\([^>]*?\\)src=\"\\([^\"]+\\)\""
     (lambda (match)
       (let* ((attrs (match-string 1 match))
              (src (match-string 2 match))
              (uri (unless (string-match-p "\\`\\(data:\\|https?:\\|//\\)" src)
                     (orgmode-docs--data-uri (expand-file-name src)))))
         (if uri (format "<img%ssrc=\"%s\"" attrs uri) match)))
     output t t)))

(defun orgmode-docs-md-math-envs (contents backend _info)
  "Export filter: rewrite LaTeX display environments for Markdown BACKENDs.
GitHub renders $$...$$ (and ```math) but not raw \\begin{equation}
blocks, so convert the common display environments. HTML backends are
untouched (MathJax handles environments natively)."
  (if (not (org-export-derived-backend-p backend 'md))
      contents
    (let ((s (string-trim contents)))
      (if (not (string-match
                "\\`\\\\begin{\\([a-z]+\\*?\\)}\\([^\0]*\\)\\\\end{\\1}\\'" s))
          contents
        (let ((env (string-remove-suffix "*" (match-string 1 s)))
              (body (string-trim (match-string 2 s))))
          (pcase env
            ((or "equation" "displaymath" "math")
             (format "$$\n%s\n$$\n" body))
            ("align"
             (format "$$\n\\begin{aligned}\n%s\n\\end{aligned}\n$$\n" body))
            ((or "gather" "eqnarray")
             (format "$$\n\\begin{gathered}\n%s\n\\end{gathered}\n$$\n" body))
            (_ contents)))))))

(with-eval-after-load 'ox
  (add-to-list 'org-export-filter-final-output-functions
               #'orgmode-docs-embed-images)
  (add-to-list 'org-export-filter-latex-environment-functions
               #'orgmode-docs-md-math-envs))

(provide 'orgmode-docs)
;;; orgmode-docs.el ends here
