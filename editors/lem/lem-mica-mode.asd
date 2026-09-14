;; ASDF system definition for the Mica language mode
(defsystem "lem-mica-mode"
  :description "Mica language mode for Lem"
  :depends-on ("lem")
  :serial t
  :components ((:file "mica-mode")))
