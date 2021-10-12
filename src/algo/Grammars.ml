open Base
open Lang.Term
open Syguslib.Sygus

type grammar_parameters =
  { g_opset : OpSet.t
  ; g_fixed_constants : bool
  ; g_mul_constant : bool
  ; g_nonlinear : bool
  ; g_locals : (sygus_term * sygus_sort) list
  ; g_bools : bool
  }

type grammar_guess =
  | GChoice of grammar_guess list
  | GBin of Binop.t * grammar_guess * grammar_guess
  | GUn of Unop.t * grammar_guess
  | GIte of grammar_guess * grammar_guess * grammar_guess
  | GType of Lang.RType.t
  | GNonGuessable

let preamble ret_sort (gguess : grammar_guess) ~(ints : sygus_term) ~(bools : sygus_term) =
  let rec build_prods gguess =
    match gguess with
    | GType t ->
      (match t with
      | TInt -> [ ints ]
      | TBool -> [ bools ]
      | TParam _ -> [ ints ]
      | _ -> [])
    | GUn (u, g) ->
      let g_prods = build_prods g in
      List.map g_prods ~f:(fun prod -> SyApp (IdSimple (Unop.to_string u), [ prod ]))
    | GBin (b, ta, tb) ->
      let prods_a = build_prods ta
      and prods_b = build_prods tb in
      let a_x_b = List.cartesian_product prods_a prods_b in
      List.map a_x_b ~f:(fun (proda, prodb) ->
          SyApp (IdSimple (Binop.to_string b), [ proda; prodb ]))
    | GIte (a, b, c) ->
      let prods_a = build_prods a
      and prods_b = build_prods b
      and prods_c = build_prods c in
      let a_x_b_x_c =
        List.cartesian_product prods_a (List.cartesian_product prods_b prods_c)
      in
      List.map a_x_b_x_c ~f:(fun (a, (b, c)) -> SyApp (IdSimple "ite", [ a; b; c ]))
    | GChoice c -> List.concat_map ~f:build_prods c
    | _ -> []
  in
  match build_prods gguess with
  | [] -> []
  | guesses -> [ ("IStart", ret_sort), List.map ~f:(fun x -> GTerm x) guesses ]
;;

let int_sort = SId (IdSimple "Int")
let bool_sort = SId (IdSimple "Bool")

let int_base : grammar_def =
  let ic = SyId (IdSimple "Ic") in
  let ix = SyId (IdSimple "Ix") in
  let ipred = SyId (IdSimple "Ipred") in
  [ ( ("Ix", int_sort)
    , [ GTerm ic
      ; GVar int_sort
      ; GTerm (SyApp (IdSimple "-", [ ix ]))
      ; GTerm (SyApp (IdSimple "+", [ ix ]))
      ; GTerm (SyApp (IdSimple "min", [ ix; ix ]))
      ; GTerm (SyApp (IdSimple "max", [ ix; ix ]))
      ; GTerm (SyApp (IdSimple "*", [ ic; ix ]))
      ; GTerm (SyApp (IdSimple "div", [ ix; ic ]))
      ; GTerm (SyApp (IdSimple "abs", [ ix ]))
      ; GTerm (SyApp (IdSimple "div", [ ix; ic ]))
      ; GTerm (SyApp (IdSimple "ite", [ ipred; ix; ix ]))
      ] )
  ; ("Ic", int_sort), [ GConstant int_sort ]
  ; ( ("Ipred", bool_sort)
    , [ GTerm (SyApp (IdSimple "=", [ ix; ix ]))
      ; GTerm (SyApp (IdSimple ">", [ ix; ix ]))
      ; GTerm (SyApp (IdSimple "not", [ ipred ]))
      ; GTerm (SyApp (IdSimple "and", [ ipred; ipred ]))
      ; GTerm (SyApp (IdSimple "or", [ ipred; ipred ]))
      ] )
  ]
;;

let int_parametric ?(guess = None) (params : grammar_parameters) =
  let ic = SyId (IdSimple "Ic") in
  let ix = SyId (IdSimple "Ix") in
  let ipred = SyId (IdSimple "Ipred") in
  let main_grammar =
    [ ( ("Ix", int_sort)
      , [ GTerm ic ]
        @ List.filter_map params.g_locals ~f:(fun (t, s) ->
              match s with
              | SId (IdSimple "Int") -> Some (GTerm t)
              | _ -> None)
        @ [ GTerm (SyApp (IdSimple "-", [ ix ])) ]
        @ [ GTerm (SyApp (IdSimple "+", [ ix; ix ])) ]
        @ (if (not params.g_nonlinear) && params.g_mul_constant
          then
            [ GTerm (SyApp (IdSimple "*", [ ic; ix ]))
            ; GTerm (SyApp (IdSimple "div", [ ix; ic ]))
            ]
          else [])
        @ (if Set.mem params.g_opset (Binary Min)
          then [ GTerm (SyApp (IdSimple "min", [ ix; ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Max)
          then [ GTerm (SyApp (IdSimple "max", [ ix; ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Times)
              || Set.mem params.g_opset (Binary Div)
              || params.g_nonlinear
          then
            [ GTerm (SyApp (IdSimple "*", [ ix; ix ]))
            ; GTerm (SyApp (IdSimple "div", [ ix; ix ]))
            ]
          else [])
        @ (if Set.mem params.g_opset (Unary Abs)
          then [ GTerm (SyApp (IdSimple "abs", [ ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Div)
          then [ GTerm (SyApp (IdSimple "div", [ ix; ic ])) ]
          else [])
        @
        if params.g_bools
        then [ GTerm (SyApp (IdSimple "ite", [ ipred; ix; ix ])) ]
        else [] )
    ]
    @ [ ( ("Ic", int_sort)
        , if params.g_fixed_constants
          then [ GTerm (SyLit (LitNum 0)); GTerm (SyLit (LitNum 1)) ]
          else [ GConstant int_sort ] )
      ]
    @
    if params.g_bools
    then
      [ ( ("Ipred", bool_sort)
        , List.filter_map params.g_locals ~f:(fun (t, s) ->
              match s with
              | SId (IdSimple "Bool") -> Some (GTerm t)
              | _ -> None)
          @ [ GTerm (SyApp (IdSimple "=", [ ix; ix ]))
            ; GTerm (SyApp (IdSimple ">", [ ix; ix ]))
            ; GTerm (SyApp (IdSimple "not", [ ipred ]))
            ; GTerm (SyApp (IdSimple "and", [ ipred; ipred ]))
            ; GTerm (SyApp (IdSimple "or", [ ipred; ipred ]))
            ] )
      ]
    else []
  in
  match guess with
  | None -> main_grammar
  | Some gguess -> preamble int_sort ~ints:ix ~bools:ipred gguess @ main_grammar
;;

let bool_parametric
    ?(guess = None)
    ?(special_const_prod = true)
    (params : grammar_parameters)
  =
  let has_ints =
    List.exists params.g_locals ~f:(fun (_, s) ->
        match s with
        | SId (IdSimple "Int") -> true
        | _ -> false)
  in
  let ic = SyId (IdSimple "Ic") in
  let ix = SyId (IdSimple "Ix") in
  let ipred = SyId (IdSimple "Ipred") in
  let bool_section =
    [ ( ("Ipred", bool_sort)
      , List.filter_map params.g_locals ~f:(fun (t, s) ->
            match s with
            | SId (IdSimple "Bool") -> Some (GTerm t)
            | _ -> None)
        @ [ GTerm (SyApp (IdSimple "not", [ ipred ]))
          ; GTerm (SyApp (IdSimple "and", [ ipred; ipred ]))
          ; GTerm (SyApp (IdSimple "or", [ ipred; ipred ]))
          ]
        @ (if List.length params.g_locals <= 0
          then [ GTerm (SyId (IdSimple "true")); GTerm (SyId (IdSimple "false")) ]
          else [])
        @
        if has_ints
        then
          (if special_const_prod
          then [ GTerm (SyApp (IdSimple "=", [ ix; ic ])) ]
          else [])
          @ [ GTerm (SyApp (IdSimple "=", [ ix; ix ]))
            ; GTerm (SyApp (IdSimple ">", [ ix; ix ]))
            ]
        else [] )
    ]
  in
  let int_section =
    [ ( ("Ix", int_sort)
      , [ GTerm ic ]
        @ List.filter_map params.g_locals ~f:(fun (t, s) ->
              match s with
              | SId (IdSimple "Int") -> Some (GTerm t)
              | _ -> None)
        @ [ GTerm (SyApp (IdSimple "-", [ ix ])) ]
        @ [ GTerm (SyApp (IdSimple "+", [ ix; ix ])) ]
        @ (if special_const_prod
          then [ GTerm (SyApp (IdSimple "+", [ ix; ic ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Min)
          then [ GTerm (SyApp (IdSimple "min", [ ix; ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Max)
          then [ GTerm (SyApp (IdSimple "max", [ ix; ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Times)
          then [ GTerm (SyApp (IdSimple "*", [ ic; ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Div)
          then [ GTerm (SyApp (IdSimple "div", [ ix; ic ])) ]
          else [])
        @ (if Set.mem params.g_opset (Unary Abs)
          then [ GTerm (SyApp (IdSimple "abs", [ ix ])) ]
          else [])
        @ (if Set.mem params.g_opset (Binary Div)
          then [ GTerm (SyApp (IdSimple "div", [ ix; ic ])) ]
          else [])
        @ [ GTerm (SyApp (IdSimple "ite", [ ipred; ix; ix ])) ]
        @
        if Set.mem params.g_opset (Binary Mod)
        then [ GTerm (SyApp (IdSimple "mod", [ ix; ic ])) ]
        else [] )
    ]
    @ [ ( ("Ic", int_sort)
        , if params.g_fixed_constants
          then [ GTerm (SyLit (LitNum 0)); GTerm (SyLit (LitNum 1)) ]
          else [ GConstant int_sort ] )
      ]
  in
  let main_grammar = if has_ints then bool_section @ int_section else bool_section in
  match guess with
  | None -> main_grammar
  | Some gguess -> preamble bool_sort ~ints:ix ~bools:ipred gguess @ main_grammar
;;

let tuple_grammar_constr (params : grammar_parameters) (sorts : sygus_sort list) =
  let use_bool = ref params.g_bools in
  let tuple_args =
    List.map sorts ~f:(function
        | SId (IdSimple "Int") -> SyId (IdSimple "Ix")
        | SId (IdSimple "Bool") ->
          use_bool := true;
          SyId (IdSimple "Ipred")
        | _ -> failwith "TODO: complex tuples not supported.")
  in
  let head_rule =
    ( ("Tr", SApp (IdSimple "Tuple", sorts))
    , [ GTerm (SyApp (IdSimple "mkTuple", tuple_args)) ] )
  in
  head_rule :: int_parametric { params with g_bools = !use_bool }
;;

let grammar_sort_decomp (sort : sygus_sort) =
  match sort with
  | SId (IdSimple "Int") -> Some int_base
  | SId (IdSimple "Bool") -> None
  | SApp (IdSimple "Tuple", _) -> None
  | _ -> None
;;

let rec project ((v, s) : sorted_var) =
  match s with
  | SId (IdSimple _) -> [ SyId (IdSimple v), s ]
  | SApp (IdSimple "Tuple", sorts) ->
    let l = List.map ~f:project (List.map ~f:(fun s -> v, s) sorts) in
    List.concat (List.mapi l ~f:tuple_sel)
  | _ -> [ SyId (IdSimple v), s ]

and tuple_sel i projs =
  List.map projs ~f:(fun (t, s) -> SyApp (IdIndexed ("tupSel", [ INum i ]), [ t ]), s)
;;

let generate_grammar
    ?(nonlinear = false)
    ?(guess = None)
    ?(bools = false)
    ?(special_const_prod = true)
    (opset : OpSet.t)
    (args : sorted_var list)
    (ret_sort : sygus_sort)
  =
  let locals_of_scalar_type = List.concat (List.map ~f:project args) in
  let params =
    { g_opset = opset
    ; g_fixed_constants = false
    ; g_mul_constant = false
    ; g_nonlinear = nonlinear
    ; g_locals = locals_of_scalar_type
    ; g_bools = bools || not (Set.are_disjoint opset OpSet.comparison_operators)
    }
  in
  match ret_sort with
  | SId (IdSimple "Int") -> Some (int_parametric ~guess params)
  | SId (IdSimple "Bool") -> Some (bool_parametric ~guess ~special_const_prod params)
  (* Ignore guess if it's a tuple that needs to be generated. *)
  | SApp (IdSimple "Tuple", sorts) -> Some (tuple_grammar_constr params sorts)
  | _ -> None
;;

(* ============================================================================================= *)
(*                          GRAMMAR OPTIMIZATION                                                 *)
(* ============================================================================================= *)

let make_basic_guess (eqns : (term * term option * term * term) list) (xi : variable) =
  let lhs_of_xi =
    let f (_, _, lhs, rhs) =
      match rhs.tkind with
      | TApp ({ tkind = TVar x; _ }, _) -> if Variable.(xi = x) then Some lhs else None
      | _ -> None
    in
    List.filter_map ~f eqns
  in
  let guesses =
    let f lhs =
      let t = lhs.ttyp in
      match lhs.tkind with
      | TBin (op, _, _) ->
        Some
          (match
             List.map
               ~f:(fun (ta, tb) -> GBin (op, GType ta, GType tb))
               (Binop.operand_types op)
           with
          | [ a ] -> a
          | _ as l -> GChoice l)
      | TUn (op, _) -> Some (GUn (op, GType (Unop.operand_type op)))
      | TIte (_, _, _) -> Some (GIte (GType Lang.RType.TBool, GType t, GType t))
      | TConst _ -> None
      | TVar _ -> None
      | _ -> Some GNonGuessable
    in
    List.filter_map ~f lhs_of_xi
  in
  match guesses with
  | [] -> None
  | hd :: tl -> if List.for_all tl ~f:(fun x -> Poly.equal x hd) then Some hd else None
;;

let make_unification_guess
    (eqns : (term * term option * term * term) list)
    (xi : variable)
  =
  make_basic_guess eqns xi
;;

let make_guess
    ?(level = 1)
    (eqns : (term * term option * term * term) list)
    (xi : variable)
  =
  match level with
  | 0 -> None
  | 1 -> make_basic_guess eqns xi
  | 2 -> make_unification_guess eqns xi
  | _ -> None
;;
