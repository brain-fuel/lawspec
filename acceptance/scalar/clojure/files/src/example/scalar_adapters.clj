;; User-owned LawSpec adapter.
(ns example.scalar-adapters
  "The adapters of example.scalar_adapters."
  (:import (lawspec.runtime LawSpecRuntime)))

;; (Char -> Char)
(defn echo-char [c] c)

;; (CodePoint -> CodePoint)
(defn echo-code-point [c] c)

;; (CodeUnit16 -> CodeUnit16)
(defn echo-code-unit [c] c)

;; (Bytes -> Bytes)
(defn echo-bytes [bytes] bytes)

;; (Complex64 -> Complex64)
(defn echo-complex [z] z)

;; (Int8 -> Integer)
(defn successor [n] (inc' n))

;; (Int8 -> Int8)
(defn narrow [n] n)

;; (Decimal -> (Decimal -> Decimal))
(defn add-decimal [a b] (+ a b))

;; (Symbol -> (Symbol -> Bool))
(defn same-symbol [a b] (LawSpecRuntime/equal a b))

;; (Utf16Text -> Utf16Text)
(defn echo-raw [text] text)

;; (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
(defn echo-presence [value] value)

;; (Unit -> Unit)
(defn finish [_] nil)

;; (UInt64 -> UInt64)
(defn preserve-big [n] n)

;; (IntSize -> IntSize)
(defn machine-echo [n] n)
