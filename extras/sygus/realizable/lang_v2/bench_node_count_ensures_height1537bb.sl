(set-logic DTLIA)
(synth-fun f0 ((x34 Int) (x35 Int)) Int ((Ix Int) (Ic Int))
 ((Ix Int (Ic x34 x35 (- Ix) (+ Ix Ix))) (Ic Int ((Constant Int)))))
(declare-var p Int)
(declare-var i106 Int)
(declare-var i107 Int)
(constraint (or (not (= i106 i107)) (= (+ (+ 1 i106) i107) (f0 p i106))))
(check-synth)