(** @synduce -s 2 -NB *)

(* The type of cons-lists *)
type 'a list =
  | Nil
  | Cons of 'a * 'a list

(* The type of list zippers: a zipper is a pair of two lists (a, b). *)
type 'a list_zipper = Zip of 'a list * 'a list

(* Representation function: reconstructing a list from a zipper. *)
let rec repr = function
  | Zip (a, b) -> conc b (rev a)

and conc x = function
  | Nil -> x
  | Cons (hd, tl) -> Cons (hd, conc x tl)

and rev = function
  | Nil -> Nil
  | Cons (hd, tl) -> conc (Cons (hd, Nil)) (rev tl)
;;

(* Reference function: the sum on lists. *)
let rec list_sum = function
  | Nil -> 0
  | Cons (hd, tl) -> hd + list_sum tl
;;

(* Target skeleton: let us assume we do not know if we can compute the reverse list sum... *)
let rec zipper_sum = function
  | Zip (a, b) -> [%synt join]

and rev_list_sum = function
  | Nil -> [%synt s0]
  | Cons (hd, tl) -> [%synt op]
;;

assert (zipper_sum = repr @@ list_sum)
