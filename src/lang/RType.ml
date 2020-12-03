open Base
open Lexing
open Utils


let _tid = ref 0


type ident = string


type typekind =
  | TyInt
  | TyBool
  | TyString
  | TyChar
  | TyFun of type_term * type_term
  | TyTyp of ident
  | TyParam of ident
  | TyConstr of (type_term list) * type_term
  | TySum of type_term list
  | TyVariant of ident * (type_term list)

and type_term = { pos : position * position; tkind : typekind }

let dummy_loc = Lexing.dummy_pos , Lexing.dummy_pos
let mk_t_int pos = {pos; tkind = TyInt}
let mk_t_bool pos = {pos; tkind = TyBool}
let mk_t_string pos = {pos; tkind = TyString}
let mk_t_char pos = {pos; tkind = TyChar }
let mk_t_typ pos t = {pos; tkind = TyTyp t }
let mk_t_param pos t = {pos; tkind = TyParam t }
let mk_t_constr pos tl t = {pos; tkind = TyConstr(tl, t)}
let mk_t_sum pos t = {pos; tkind = TySum t }
let mk_t_variant pos c t = {pos; tkind = TyVariant (c, t) }
let mk_t_fun pos t1 t2 = {pos; tkind = TyFun(t1, t2) }


type t =
  | TInt
  | TBool
  | TString
  | TChar
  | TNamed of ident
  | TTup of t list
  | TFun of t * t
  | TParam of t list * t
  | TVar of int

let _tvar_idx = ref 0
let get_fresh_tvar () = Int.incr _tvar_idx; TVar (!_tvar_idx)

let rec pp (frmt : Formatter.t) (typ : t) =
  match typ with
  | TInt -> Fmt.(pf frmt "int")
  | TBool -> Fmt.(pf frmt "bool")
  | TString -> Fmt.(pf frmt "string")
  | TChar -> Fmt.(pf frmt "char")
  | TNamed s -> Fmt.(pf frmt "%s" s)
  | TTup tl -> Fmt.(pf frmt "%a" (parens (list ~sep:comma pp)) tl)
  | TFun (tin, tout) -> Fmt.(pf frmt "%a -> %a" pp tin pp tout)
  | TParam (alpha, t') ->
    Fmt.(pf frmt "%a[%a]" pp t' (list ~sep:comma pp) alpha)
  | TVar i -> Fmt.(pf frmt "α%i" i)
(**
   This hashtable maps type names to the type term of their declaration.
   It is initialized with the builtin types int, bool, char and string.
*)
let _types : (ident, ident list * type_term) Hashtbl.t =
  Hashtbl.of_alist_exn (module String)
    [ "int", ([], mk_t_int dummy_loc);
      "bool", ([], mk_t_bool dummy_loc);
      "char", ([], mk_t_char dummy_loc);
      "string", ([], mk_t_string dummy_loc)]

(**
   This hashtable maps variant names to the type name.
   Variant names must be unique!
*)
let _variants : (string, string) Hashtbl.t = Hashtbl.create (module String)


(* Add the builtin types *)
let add_variant ~(variant : string) ~(typename: string) =
  Hashtbl.add _variants ~key:variant ~data:typename


let add_type ?(params: ident list = [])  ~(typename: string) (tterm : type_term) =
  let add_only () =
    match Hashtbl.add _types ~key:typename ~data:(params, tterm) with
    | `Ok -> Ok ()
    | `Duplicate ->
      Error Log.(satom (Fmt.str "Type %s already declared" typename) @! tterm.pos)
  in
  let add_with_variants variants =
    Result.(
      List.fold_result ~init:[]
        ~f:(fun l variant ->
            match variant.tkind with
            | TyVariant (n, _) -> Ok ((n, variant.pos)::l)
            | _ ->
              Error Log.((satom "Sum types should only have constructor variants.") @! variant.pos))
        variants
      >>=
      List.fold_result ~init:()
        ~f:(fun _ (vname, pos) ->
            match add_variant ~variant:vname ~typename with
            | `Ok -> Ok ()
            | `Duplicate ->
              Error Log.((satom Fmt.(str "Variant %s already declared" vname)) @! pos))
      >>=
      (fun _ -> add_only ()))
  in
  match tterm.tkind with
  | TySum variants -> add_with_variants variants
  | _ -> add_only ()


let instantiate_variant (variants : type_term list) (instantiator : (ident * int) list) =
  let rec variant_arg tt =
    match tt.tkind with
    | TyInt -> TInt | TyBool -> TBool | TyChar -> TChar | TyString -> TString
    | TyFun (tin, tout) -> TFun(variant_arg tin, variant_arg tout)
    | TyTyp e -> TNamed e
    | TyParam x ->
      (match List.Assoc.find instantiator ~equal:String.equal x with
       | Some i -> TVar i
       | None -> Log.loc_fatal_errmsg tt.pos "Unknown type parameter.")
    | TySum _ -> Log.loc_fatal_errmsg tt.pos "Variant is a sum type."
    | TyVariant (_, tl) -> TTup(List.map ~f:variant_arg tl)
    | TyConstr (params, te) -> TParam(List.map ~f:variant_arg params, variant_arg te)
  in
  List.map variants ~f:variant_arg


let type_of_variant (variant : string) : (t * t list) option =
  match Hashtbl.find _variants variant with
  | Some tname ->
    (match Hashtbl.find _types tname with
     | Some (params, {tkind = TySum tl; _}) ->
       (match params with
        | [] -> Some (TNamed tname, [])
        | _ ->
          let ty_params_inst =
            List.map
              ~f:(fun s ->
                  match get_fresh_tvar () with
                  |TVar i -> s, i
                  | _ -> failwith "unexpected")
              params
          in
          let variant_args =
            let x = List.find_map
                ~f:(fun e ->
                    match e.tkind with
                    | TyVariant(n, var_args) ->
                      if String.(n = variant) then Some var_args else None
                    | _ -> None)
                tl
            in match x with
            | Some y -> y
            | None -> failwith "Could not find variant."
          in
          Some (TParam(List.map ~f:(fun (_,b) -> TVar b) ty_params_inst, TNamed tname),
                instantiate_variant variant_args ty_params_inst))
     | _ -> None)
  | None -> None


(* ============================================================================================= *)


let substitute ~(old:t) ~(by:t) ~(in_: t) =
  let rec s ty =
    if Poly.(ty = old) then by else
      match ty with
      | TInt | TBool | TChar | TString | TNamed _ | TVar _ -> ty
      | TTup tl -> TTup (List.map ~f:s tl)
      | TFun (a,b) -> TFun(s a, s b)
      | TParam(params, t) -> TParam(List.map ~f:s params, s t)
  in s in_

let sub_all (subs : (t * t) list) (ty : t) =
  List.fold_right ~f:(fun (old, by) acc -> substitute ~old ~by ~in_:acc) ~init:ty subs

let rec subtype_of (t1 : t) (t2 : t) =
  if Poly.(t1 = t2) then true else
    match t1, t2 with
    | TFun(a1, b1), TFun(a2, b2) -> subtype_of a2 a1 && subtype_of b1 b2
    | TTup tl1, TTup tl2 ->
      let f a b = subtype_of a b in
      (match List.for_all2 ~f tl1 tl2 with
       | Ok b -> b
       | Unequal_lengths -> false)
    | TParam (p1, t1'), TParam (p2, t2') ->
      (match List.zip p1 p2 with
       | Ok subs -> subtype_of (sub_all subs t1') t2'
       | Unequal_lengths -> false)
    | _ -> false


let rec occurs (x : int) (typ : t) : bool =
  match typ with
  | TInt | TBool | TString | TChar | TNamed _ -> false
  | TTup tl -> List.exists ~f:(occurs x) tl
  | TFun (tin, tout) -> occurs x tin || occurs x tout
  | TParam (param, te) -> List.exists ~f:(occurs x) param || occurs x te
  | TVar y -> x = y

type substitution = (int * t) list

(* unify one pair *)
let rec unify_one (s : t) (t : t) : substitution option =
  match (s, t) with
  | TVar x, TVar y -> if x = y then Some [] else Some [(x, t)]
  | TFun (f, sc), TFun (g, tc) ->
    Option.(unify_one f g >>=
            (fun u1 -> match unify_one sc tc with
               | Some u2 -> unify ((mkv u1) @ (mkv u2))
               | None ->
                 (Log.error
                    (fun frmt () ->
                       Fmt.(pf frmt "Type unification: cannot unify %a and %a.") pp s pp t);
                  None)))
  | TParam(params1, t1), TParam(params2, t2) ->
    (match List.zip (params1 @ [t1]) (params2 @ [t2]) with
     | Ok pairs -> unify pairs
     | Unequal_lengths -> (Log.error
                             (fun frmt () ->
                                Fmt.(pf frmt "Type unification: cannot unify %a and %a.") pp s pp t);
                           None))

  | TTup tl1, TTup tl2 ->
    (match List.zip tl1 tl2 with
     | Ok tls -> unify tls
     | Unequal_lengths ->
       Log.error
         (fun frmt () ->
            Fmt.(pf frmt "Type unification: Tuples %a and %a have different sizes") pp s pp t);
       None)
  | (TVar x, t' | t', TVar x) ->
    if occurs x t'
    then
      (Log.error
         (fun frmt () ->
            Fmt.(pf frmt "Type unification: circularity %a - %a") pp s pp t);
       None)
    else Some [x, t']
  | _ -> if Poly.equal s t then Some [] else
      (Log.error
         (fun frmt () ->
            Fmt.(pf frmt "Type unification: cannot unify %a and %a") pp s pp t);
       None)

and mkv = List.map ~f:(fun (a, b) -> (TVar a, b))
(* unify a list of pairs *)
and unify (s : (t * t) list) : substitution option =
  match s with
  | [] -> Some []
  | (x, y) :: t ->
    Option.(unify t
            >>=(fun t2 -> unify_one (sub_all (mkv t2) x) (sub_all (mkv t2) y)
                 >>= (fun t1 -> Some (t1 @ t2))))

let merge_subs loc (s : substitution) (t : substitution) : substitution =
  match unify (List.map ~f:(fun (a,b) -> TVar a, b) (s @ t)) with
  | Some subs -> subs
  | None -> Log.loc_fatal_errmsg loc "Error merging constraints."