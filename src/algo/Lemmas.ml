open AState
open Base
open Counterexamples
open Lang
open Lang.Term
open Syguslib.Sygus
open SygusInterface
open Utils
open Smtlib
module Smt = SmtInterface
module S = Smtlib.SmtLib
module T = Term

let make_new_recurs_elim_from_term (term : term) ~(p : psi_def) : (term * term) list * variable list
    =
  Set.fold ~init:([], [])
    ~f:(fun (rec_elim, vars) var ->
      match Variable.vtype var with
      | None -> (rec_elim, var :: vars)
      | Some t ->
          if RType.is_recursive t then
            match Expand.mk_recursion_elimination_term p with
            | None -> (rec_elim, vars)
            | Some (a, _) ->
                (* When are a and b different? *)
                ((mk_var var, a) :: rec_elim, vars @ Set.elements (Analysis.free_variables a))
          else (rec_elim, var :: vars))
    (Analysis.free_variables term)

let make_term_state_detail ~(p : psi_def) (term : term) : term_state_detail =
  let recurs_elim, scalar_vars = make_new_recurs_elim_from_term ~p term in
  {
    term;
    lemmas = [];
    lemma_candidate = None;
    negative_ctexs = [];
    positive_ctexs = [];
    recurs_elim;
    scalar_vars;
    current_preconds = None;
    ctex =
      (* TODO: this is hacky. Make ctex optional here. *)
      {
        ctex_vars = VarSet.empty;
        ctex_eqn = { eterm = term; eprecond = None; eelim = []; elhs = term; erhs = term };
        ctex_model = Map.empty (module Int);
      };
  }

let subs_from_elim_to_elim elim1 elim2 : (term * term) list =
  List.map
    ~f:(fun (a, b) ->
      let rec f lst =
        match lst with
        | [] -> failwith "Failed to get subs from ctex to term elims."
        | (a', b') :: tl -> if Terms.(equal a a') then (b', b) else f tl
      in
      f elim2)
    elim1

let make_term_state_detail_from_ctex ~(p : psi_def) (is_pos_ctex : bool) (ctex : ctex) :
    term_state_detail =
  let neg = if is_pos_ctex then [] else [ ctex ] in
  let pos = if is_pos_ctex then [ ctex ] else [] in
  let recurs_elim, scalar_vars = make_new_recurs_elim_from_term ~p ctex.ctex_eqn.eterm in
  {
    term = ctex.ctex_eqn.eterm;
    lemmas = [];
    lemma_candidate = None;
    negative_ctexs = neg;
    positive_ctexs = pos;
    recurs_elim;
    scalar_vars;
    current_preconds =
      (match ctex.ctex_eqn.eprecond with
      | None -> None
      | Some pre -> Some (substitution (subs_from_elim_to_elim recurs_elim ctex.ctex_eqn.eelim) pre));
    ctex;
  }

let mk_f_compose_r_orig ~(p : psi_def) (t : term) : term =
  let repr_of_v = if p.psi_repr_is_identity then t else mk_app_v p.psi_repr.pvar [ t ] in
  mk_app_v p.psi_reference.pvar (List.map ~f:mk_var p.psi_reference.pargs @ [ repr_of_v ])

let mk_f_compose_r_main ~(p : psi_def) (t : term) : term =
  let repr_of_v = if p.psi_repr_is_identity then t else mk_app_v p.psi_repr.pmain_symb [ t ] in
  mk_app_v p.psi_reference.pmain_symb [ repr_of_v ]

let term_detail_to_lemma ~(p : psi_def) (det : term_state_detail) : term option =
  let subst =
    List.map
      ~f:(fun (t1, t2) ->
        let frt1 = mk_f_compose_r_main ~p t1 in
        (t2, frt1))
      det.recurs_elim
  in
  let f lem = Term.substitution subst lem in
  (* let f _lem = Term.mk_const CTrue in *)
  let result = T.mk_assoc Binop.And (List.map ~f det.lemmas) in
  match result with
  | None -> result
  | Some x ->
      Log.debug (fun frmt () ->
          Fmt.pf frmt "This is the lemma after substitution: \"@[%a@]\"." pp_term x);
      result

let empty_term_state : term_state = Map.empty (module Terms)

let set_term_lemma ~(p : psi_def) (ts : term_state) ~(key : term) ~(lemma : term) : term_state =
  match Map.find ts key with
  | None -> Map.add_exn ts ~key ~data:{ (make_term_state_detail ~p key) with lemmas = [ lemma ] }
  | Some det -> Map.add_exn ts ~key ~data:{ det with lemmas = [ lemma ] }

let create_or_update_term_state_for_ctex ~(p : psi_def) (is_pos_ctex : bool) (ts : term_state)
    (ctex : ctex) : term_state =
  match Map.find ts ctex.ctex_eqn.eterm with
  | None ->
      Map.add_exn ~key:ctex.ctex_eqn.eterm
        ~data:(make_term_state_detail_from_ctex ~p is_pos_ctex ctex)
        ts
  | Some _ ->
      Map.update ts ctex.ctex_eqn.eterm ~f:(fun maybe_det ->
          match maybe_det with
          | None -> failwith "Term detail does not exist."
          | Some det ->
              if is_pos_ctex then { det with positive_ctexs = ctex :: det.positive_ctexs }
              else
                {
                  det with
                  current_preconds =
                    (match ctex.ctex_eqn.eprecond with
                    | None -> None
                    | Some pre ->
                        Some
                          (substitution
                             (subs_from_elim_to_elim det.recurs_elim ctex.ctex_eqn.eelim)
                             pre));
                  negative_ctexs = ctex :: det.negative_ctexs;
                })

let update_term_state_for_ctexs ~(p : psi_def) (ts : term_state) ~(pos_ctexs : ctex list)
    ~(neg_ctexs : ctex list) : term_state =
  List.fold
    ~init:(List.fold ~init:ts ~f:(create_or_update_term_state_for_ctex ~p true) pos_ctexs)
    ~f:(create_or_update_term_state_for_ctex ~p false)
    neg_ctexs

let get_lemma ~(p : psi_def) (ts : term_state) ~(key : term) : term option =
  match Map.find ts key with None -> None | Some det -> term_detail_to_lemma ~p det

let get_term_state_detail (ts : term_state) ~(key : term) = Map.find ts key

let add_lemmas_interactively ~(p : psi_def) (lstate : refinement_loop_state) : refinement_loop_state
    =
  let env_in_p = VarSet.of_list p.psi_reference.pargs in
  let f existing_lemmas t =
    let vars = Set.union (Analysis.free_variables t) env_in_p in
    let env = VarSet.to_env vars in

    Log.info (fun frmt () -> Fmt.pf frmt "Please provide a constraint for \"@[%a@]\"." pp_term t);
    Log.verbose (fun frmt () ->
        Fmt.pf frmt "Environment:@;@[functions %s, %s and %s@]@;and @[%a@]."
          p.psi_reference.pvar.vname p.psi_target.pvar.vname p.psi_repr.pvar.vname VarSet.pp vars);
    match Stdio.In_channel.input_line Stdio.stdin with
    | None | Some "" ->
        Log.info (fun frmt () -> Fmt.pf frmt "No additional constraint provided.");
        existing_lemmas
    | Some x -> (
        let smtterm =
          try
            let sexpr = Sexplib.Sexp.of_string x in
            Smtlib.SmtLib.smtTerm_of_sexp sexpr
          with Failure _ -> None
        in
        let pred_term = SmtInterface.term_of_smt env in
        let term x =
          match get_lemma ~p existing_lemmas ~key:t with
          | None -> pred_term x
          | Some inv -> mk_bin Binop.And inv (pred_term x)
        in
        match smtterm with
        | None -> existing_lemmas
        | Some x -> set_term_lemma ~p existing_lemmas ~key:t ~lemma:(term x))
  in
  { lstate with term_state = Set.fold ~f ~init:lstate.term_state lstate.t_set }

let ith_synth_fun index = "lemma_" ^ Int.to_string index

let synthfun_of_ctex ~(p : psi_def) (det : term_state_detail) (lem_id : int) :
    command * (string * sygus_sort) list =
  let params =
    List.map
      ~f:(fun scalar -> (scalar.vname, sort_of_rtype RType.TInt))
      (p.psi_reference.pargs @ det.scalar_vars)
  in
  let ret_sort = sort_of_rtype RType.TBool in
  let grammar = Grammars.generate_grammar ~guess:None ~bools:true OpSet.empty params ret_sort in
  (CSynthFun (ith_synth_fun lem_id, params, ret_sort, grammar), params)

let term_var_string term : string =
  match Set.elements (Analysis.free_variables term) with
  | [] -> failwith (Fmt.str "Failed to extract string of variable name in term %a" pp_term term)
  | var :: _ -> var.vname

let convert_term_rec_to_ctex_rec ~(p : psi_def) (det : term_state_detail) (ctex : ctex)
    (name : string) : string =
  let rec g recvar lst =
    match lst with
    | [] -> failwith (Fmt.str "Could not convert name %s to ctex rec elim." name)
    | (a, b) :: tl ->
        let i = term_var_string b in
        let l = term_var_string a in
        if String.(equal l recvar) then i else g recvar tl
  in
  let rec f lst =
    match lst with
    | [] -> failwith (Fmt.str "Could not convert name %s to ctex rec elim." name)
    | (a, b) :: tl ->
        let i = term_var_string b in
        let l = term_var_string a in
        if String.(equal i name) then g l ctex.ctex_eqn.eelim else f tl
  in
  match
    VarSet.find_by_name (Set.union (VarSet.of_list p.psi_reference.pargs) ctex.ctex_vars) name
  with
  | None -> f det.recurs_elim
  | Some _ -> name

let ctex_model_to_args ~(p : psi_def) (det : term_state_detail)
    (params : (string * sygus_sort) list) ctex : sygus_term list =
  List.map
    ~f:(fun (name_, _) ->
      match
        let name = convert_term_rec_to_ctex_rec ~p det ctex name_ in
        Map.find ctex.ctex_model
          (match
             VarSet.find_by_name
               (Set.union (VarSet.of_list p.psi_reference.pargs) ctex.ctex_vars)
               name
           with
          | None ->
              failwith
                (Fmt.str "Failed to extract argument list from ctex model (%s unknown)." name)
          | Some v -> v.vid)
      with
      | None -> failwith "Failed to extract argument list from ctex model."
      | Some t -> sygus_of_term t)
    params

let constraint_of_neg_ctex index ~(p : psi_def) (det : term_state_detail)
    (params : (string * sygus_sort) list) ctex =
  CConstraint
    (SyApp
       ( IdSimple "not",
         [ SyApp (IdSimple (ith_synth_fun index), ctex_model_to_args ~p det params ctex) ] ))

let constraint_of_pos_ctex index ~(p : psi_def) (det : term_state_detail)
    (params : (string * sygus_sort) list) ctex =
  CConstraint (SyApp (IdSimple (ith_synth_fun index), ctex_model_to_args ~p det params ctex))

let log_soln s vs t =
  Log.verbose (fun frmt () ->
      Fmt.pf frmt "Lemma candidate: \"%s %s = @[%a@]\"." s
        (String.concat ~sep:" " (List.map ~f:(fun v -> v.vname) vs))
        pp_term t)

let handle_lemma_synth_response ~(p : psi_def) (det : term_state_detail)
    (resp : solver_response option) =
  let parse_synth_fun (fname, _fargs, _, fbody) =
    let args = p.psi_reference.pargs @ det.scalar_vars in
    let body, _ =
      infer_type
        (term_of_sygus
           (VarSet.to_env (VarSet.of_list (p.psi_reference.pargs @ det.scalar_vars)))
           fbody)
    in
    (fname, args, body)
  in
  match resp with
  | Some (RSuccess resps) ->
      let soln = List.map ~f:parse_synth_fun resps in
      let _ = List.iter ~f:(fun (s, vs, t) -> log_soln s vs t) soln in
      Some soln
  | Some RInfeasible | Some RFail | Some RUnknown | None -> None

let smt_of_recurs_elim_eqns (elim : (term * term) list) ~(p : psi_def) : S.smtTerm =
  S.mk_assoc_and
    (List.map
       ~f:(fun (t1, t2) ->
         S.mk_eq (Smt.smt_of_term (mk_f_compose_r_orig ~p t1)) (Smt.smt_of_term t2))
       elim)

let smt_of_tinv_app ~(p : psi_def) (det : term_state_detail) =
  match p.psi_tinv with
  | None -> failwith "No TInv has been specified. Cannot make smt of tinv app."
  | Some pmrs -> S.mk_simple_app pmrs.pvar.vname [ Smt.smt_of_term det.term ]

let smt_of_lemma_app (lemma_name, lemma_args, _lemma_body) =
  S.mk_simple_app lemma_name (List.map ~f:(fun var -> S.mk_var var.vname) lemma_args)

let smt_of_lemma_validity ~(p : psi_def) lemma (det : term_state_detail) =
  let mk_sort maybe_rtype =
    match maybe_rtype with None -> S.mk_int_sort | Some rtype -> Smt.sort_of_rtype rtype
  in
  let quants =
    List.map
      ~f:(fun var -> (S.SSimple var.vname, mk_sort (Variable.vtype var)))
      (Set.elements (Analysis.free_variables det.term)
      @ p.psi_reference.pargs
      @ List.concat_map ~f:(fun (_, b) -> Set.elements (Analysis.free_variables b)) det.recurs_elim
      )
  in
  let preconds =
    match det.current_preconds with None -> [] | Some pre -> [ Smt.smt_of_term pre ]
  in
  (* TODO: if condition should account for other preconditions *)
  let if_condition =
    S.mk_assoc_and
      ([ smt_of_tinv_app ~p det; smt_of_recurs_elim_eqns det.recurs_elim ~p ] @ preconds)
  in
  let if_then = smt_of_lemma_app lemma in
  [ S.mk_assert (S.mk_not (S.mk_forall quants (S.mk_or (S.mk_not if_condition) if_then))) ]

let set_up_lemma_solver solver ~(p : psi_def) lemma_candidate =
  Solvers.set_logic solver "ALL";
  Solvers.set_option solver "quant-ind" "true";
  Solvers.set_option solver "produce-models" "true";
  Solvers.set_option solver "incremental" "true";
  if !Config.induction_proof_tlimit >= 0 then
    Solvers.set_option solver "tlimit" (Int.to_string !Config.induction_proof_tlimit);
  Solvers.load_min_max_defs solver;
  List.iter
    ~f:(fun x -> ignore (Solvers.exec_command solver x))
    ((match p.psi_tinv with None -> [] | Some tinv -> Smt.smt_of_pmrs tinv)
    @ (if p.psi_repr_is_identity then Smt.smt_of_pmrs p.psi_reference
      else Smt.smt_of_pmrs p.psi_reference @ Smt.smt_of_pmrs p.psi_repr)
    (* Declare lemmas. *)
    @ [
        (match lemma_candidate with
        | name, vars, body ->
            Smt.mk_def_fun_command name
              (List.map ~f:(fun v -> (v.vname, RType.TInt)) vars)
              RType.TBool body);
      ])

let classify_ctexs_opt ~(p : psi_def) ctexs =
  if !Config.classify_ctex then
    let f (p, n, u) ctex =
      Log.info (fun frmt () ->
          Fmt.(pf frmt "Classify this counterexample: %a (P/N/U)" (box pp_ctex) ctex));
      match Stdio.In_channel.input_line Stdio.stdin with
      | Some "N" -> (p, ctex :: n, u)
      | Some "P" -> (ctex :: p, n, u)
      | _ -> (p, n, ctex :: u)
    in
    List.fold ~f ~init:([], [], []) ctexs
  else classify_ctexs ~p ctexs

let smt_of_disallow_ctex_values (ctexs : ctex list) : S.smtTerm =
  S.mk_assoc_and
    (List.map
       ~f:(fun ctex ->
         S.mk_not
           (S.mk_assoc_and
              (Map.fold
                 ~f:(fun ~key ~data acc ->
                   let var =
                     match VarSet.find_by_id ctex.ctex_vars key with
                     | None -> failwith "Something went wrong."
                     | Some v -> v
                   in
                   S.mk_eq (S.mk_var var.vname) (Smt.smt_of_term data) :: acc)
                 ~init:[] ctex.ctex_model)))
       ctexs)

let set_up_to_get_model solver ~(p : psi_def) lemma (det : term_state_detail) =
  (* Step 1. Declare vars for term, and assert that term satisfies tinv. *)
  Solvers.declare_all solver (Smt.decls_of_vars (Analysis.free_variables det.term));
  ignore (Solvers.exec_command solver (S.mk_assert (smt_of_tinv_app ~p det)));
  ignore (Solvers.check_sat solver);
  (* ^ Why do I do this sat check? *)
  (* Step 2. Declare scalars (vars for recursion elimination & spec param) and their constraints (preconds & recurs elim eqns) *)
  Solvers.declare_all solver
    (Smt.decls_of_vars
       (Set.union (VarSet.of_list det.scalar_vars) (VarSet.of_list p.psi_reference.pargs)));
  ignore (Solvers.exec_command solver (S.mk_assert (smt_of_recurs_elim_eqns det.recurs_elim ~p)));
  (match det.current_preconds with
  | None -> ()
  | Some pre -> ignore (Solvers.exec_command solver (S.mk_assert (Smt.smt_of_term pre))));
  ignore (Solvers.check_sat solver);
  (* Step 3. Disallow repeated positive examples. *)
  (* if List.length det.positive_ctexs > 0 then
     ignore
       (Solvers.exec_command solver (S.mk_assert (smt_of_disallow_ctex_values det.positive_ctexs))); *)
  (* Step 4. Assert that lemma candidate is false. *)
  ignore (Solvers.exec_command solver (S.mk_assert (S.mk_not (smt_of_lemma_app lemma))))

let bounded_check solver ~(p : psi_def) lemma_candidate (det : term_state_detail) :
    Solvers.solver_response * Solvers.solver_response option =
  set_up_to_get_model solver ~p lemma_candidate det;
  let steps = ref 0 in
  let rec check_bounded_sol terms =
    let f t =
      let rec_instantation =
        Option.value ~default:VarMap.empty (Analysis.matches t ~pattern:det.term)
      in
      Solvers.spush solver;
      Map.iteri
        ~f:(fun ~key ~data ->
          (* Declare variables in term `data` *)
          Solvers.declare_all solver (Smt.decls_of_vars (Analysis.free_variables data));
          (* Assert that `key` variable is equal to `data` term *)
          ignore
            (Solvers.exec_command solver
               (S.mk_assert (S.mk_eq (S.mk_var key.vname) (Smt.smt_of_term data)))))
        rec_instantation;
      let resp = Solvers.check_sat solver in
      (* Note that I am getting a model after check-sat unknown response. This may not halt.  *)
      let result =
        match resp with SmtLib.Sat | SmtLib.Unknown -> Some (Solvers.get_model solver) | _ -> None
      in
      Solvers.spop solver;
      (resp, result)
    in
    match terms with
    | [] -> None
    | t0 :: tl -> (
        match f t0 with
        | status, Some model -> Some (status, Some model)
        | _ -> check_bounded_sol tl)
  in
  let rec expand_loop u =
    match (Set.min_elt u, !steps < !Config.num_expansions_check) with
    | Some t0, true -> (
        let tset, u' = Expand.simple t0 in
        let check_result = check_bounded_sol (Set.elements tset) in
        steps := !steps + Set.length tset;
        match check_result with
        | Some (_, Some model) -> (SmtLib.Sat, Some model)
        | _ -> expand_loop (Set.union (Set.remove u t0) u'))
    | None, true ->
        (* All expansions have been checked. *)
        (SmtLib.Unsat, None)
    | _, false ->
        (* Check reached limit. *)
        if !Config.bounded_lemma_check then (SmtLib.Unsat, None) else (SmtLib.Unknown, None)
  in
  let res = expand_loop (TermSet.singleton det.term) in
  res

let verify_lemma_candidate ~(p : psi_def) (det : term_state_detail) :
    Solvers.online_solver * (Solvers.solver_response * Solvers.solver_response option) =
  match det.lemma_candidate with
  | None -> failwith "Cannot verify lemma candidate; there is none."
  | Some lemma_candidate ->
      Log.verbose (fun f () -> Fmt.(pf f "Checking lemma candidate..."));
      (* This solver is later closed in lemma_refinement_loop *)
      let solver = Smtlib.Solvers.make_cvc4_solver () in
      set_up_lemma_solver solver ~p lemma_candidate;
      let result =
        if !Config.bounded_lemma_check then bounded_check solver ~p lemma_candidate det
        else (
          List.iter
            ~f:(fun x -> ignore (Solvers.exec_command solver x))
            (smt_of_lemma_validity ~p lemma_candidate det);
          (Solvers.check_sat solver, None))
      in
      (solver, result)

let parse_positive_example_solver_model ~(p : psi_def) response (det : term_state_detail) =
  match response with
  | SmtLib.SExps s ->
      let model = Smt.model_to_constmap (SExps s) in
      let m, _ =
        Map.partitioni_tf
          ~f:(fun ~key ~data:_ ->
            Option.is_some
              (VarSet.find_by_name (VarSet.of_list (det.scalar_vars @ p.psi_reference.pargs)) key))
          model
      in
      (* Remap the names to ids of the original variables in m' *)
      [
        ({
           ctex_eqn = { det.ctex.ctex_eqn with eelim = det.recurs_elim };
           ctex_vars = VarSet.of_list det.scalar_vars;
           ctex_model =
             Map.fold
               ~init:(Map.empty (module Int))
               ~f:(fun ~key ~data acc ->
                 match
                   VarSet.find_by_name
                     (VarSet.of_list (p.psi_reference.pargs @ det.scalar_vars))
                     key
                 with
                 | None ->
                     Log.info (fun f () -> Fmt.(pf f "Could not find by name %s" key));
                     acc
                 | Some var -> Map.set ~data acc ~key:var.vid)
               m;
         }
          : ctex);
      ]
  | _ -> failwith "Parse model failure: Positive example cannot be found during lemma refinement."

let get_positive_examples (solver : Solvers.online_solver) (det : term_state_detail) ~(p : psi_def)
    (lemma : symbol * variable list * term) : ctex list =
  Log.verbose (fun f () -> Fmt.(pf f "Searching for a positive example."));
  set_up_to_get_model solver ~p lemma det;
  match Solvers.check_sat solver with
  | Sat | Unknown -> parse_positive_example_solver_model ~p (Solvers.get_model solver) det
  | _ -> failwith "Check sat failure: Positive example cannot be found during lemma refinement."

let trim (s : string) = Str.global_replace (Str.regexp "[\r\n\t ]") "" s

let parse_interactive_positive_example (det : term_state_detail) (input : string) : ctex option =
  Some
    {
      det.ctex with
      ctex_model =
        List.fold
          ~init:(Map.empty (module Int))
          ~f:(fun acc s_ ->
            let s = Str.split (Str.regexp " *= *") s_ in
            if not (equal (List.length s) 2) then acc
            else
              let key = trim (List.nth_exn s 0) in
              let data = mk_const (CInt (Int.of_string (trim (List.nth_exn s 1)))) in
              match VarSet.find_by_name (VarSet.of_list det.scalar_vars) key with
              | None -> acc
              | Some var -> Map.set ~data acc ~key:var.vid)
          (Str.split (Str.regexp " *, *") input);
    }

let interactive_get_positive_examples (det : term_state_detail) =
  let vars =
    Set.filter
      ~f:(fun var ->
        match Variable.vtype var with None -> false | Some t -> not (RType.is_recursive t))
      (Analysis.free_variables det.term)
  in
  Log.info (fun f () ->
      Fmt.(
        pf f "Enter an example as \"%s\""
          (String.concat ~sep:", "
             (List.map
                ~f:(fun var ->
                  var.vname ^ "=<"
                  ^ (match Variable.vtype var with
                    | None -> ""
                    | Some t -> ( match RType.base_name t with None -> "" | Some tname -> tname))
                  ^ ">")
                (Set.elements vars)))));
  match Stdio.In_channel.input_line Stdio.stdin with
  | None -> []
  | Some s -> (
      match parse_interactive_positive_example det s with None -> [] | Some ctex -> [ ctex ])

let synthesize_new_lemma ~(p : psi_def) (det : term_state_detail) :
    (string * variable list * term) option =
  let set_logic = CSetLogic "DTLIA" in
  (* TODO: How to choose logic? *)
  let lem_id = 0 in
  let synth_objs, params = synthfun_of_ctex ~p det lem_id in
  let neg_constraints =
    List.map ~f:(constraint_of_neg_ctex lem_id ~p det params) det.negative_ctexs
  in
  let pos_constraints =
    List.map ~f:(constraint_of_pos_ctex lem_id ~p det params) det.positive_ctexs
  in
  let extra_defs = [ max_definition; min_definition ] in
  let commands =
    set_logic :: (extra_defs @ [ synth_objs ] @ neg_constraints @ pos_constraints @ [ CCheckSynth ])
  in
  match
    handle_lemma_synth_response ~p det (Syguslib.Solvers.SygusSolver.solve_commands commands)
  with
  | None -> None
  | Some solns -> List.nth solns 0
(* TODO: will the lemma we wanted to synth always be first? *)

let rec lemma_refinement_loop (det : term_state_detail) ~(p : psi_def) : term_state_detail option =
  match synthesize_new_lemma ~p det with
  | None ->
      Log.debug_msg "Lemma synthesis failure.";
      None
  | Some (name, vars, lemma_term) -> (
      if !Config.interactive_check_lemma then (
        Log.info (fun f () ->
            Fmt.(
              pf f "Is the lemma \"%s %s = @[%a@]\" for term %a[%a] correct? [Y/N]" name
                (String.concat ~sep:" " (List.map ~f:(fun v -> v.vname) vars))
                pp_term lemma_term pp_term det.term pp_subs det.recurs_elim));
        match Stdio.In_channel.input_line Stdio.stdin with
        | Some "Y" ->
            let lemma =
              match det.current_preconds with
              | None -> lemma_term
              | Some pre -> mk_bin Binop.Or (mk_un Unop.Not pre) lemma_term
            in
            Some { det with lemma_candidate = None; lemmas = lemma :: det.lemmas }
        | _ -> (
            Log.info (fun f () ->
                Fmt.(
                  pf f
                    "Would you like to provide a non-spurious example in which the lemma is false? \
                     [Y/N]"));
            match Stdio.In_channel.input_line Stdio.stdin with
            | Some "Y" ->
                lemma_refinement_loop
                  {
                    det with
                    positive_ctexs = det.positive_ctexs @ interactive_get_positive_examples det;
                  }
                  ~p
            | _ -> None))
      else
        match
          verify_lemma_candidate ~p { det with lemma_candidate = Some (name, vars, lemma_term) }
        with
        | solver, (Unsat, _) ->
            Log.verbose (fun f () -> Fmt.(pf f "This lemma has been proven correct."));
            Solvers.close_solver solver;
            Log.info (fun frmt () ->
                Fmt.pf frmt "Lemma for term %a: \"%s %s = @[%a@]\"." pp_term det.term name
                  (String.concat ~sep:" " (List.map ~f:(fun v -> v.vname) vars))
                  pp_term lemma_term);
            let lemma =
              match det.current_preconds with
              | None -> lemma_term
              | Some pre -> mk_bin Binop.Or (mk_un Unop.Not pre) lemma_term
            in
            Some { det with lemma_candidate = None; lemmas = lemma :: det.lemmas }
        | solver, (Sat, maybe_model) | solver, (Unknown, maybe_model) ->
            Log.verbose (fun f () ->
                Fmt.(pf f "This lemma has not been proven correct. Refining lemma..."));
            let new_positive_ctexs =
              match maybe_model with
              | Some model -> parse_positive_example_solver_model ~p model det
              | _ -> get_positive_examples solver det ~p (name, vars, lemma_term)
            in
            List.iter
              ~f:(fun ctex ->
                Log.verbose (fun f () ->
                    Fmt.(pf f "Found a positive example: %a" (box pp_ctex) ctex)))
              new_positive_ctexs;
            Solvers.close_solver solver;
            lemma_refinement_loop
              { det with positive_ctexs = det.positive_ctexs @ new_positive_ctexs }
              ~p
        | _ ->
            Log.error_msg "Lemma verification returned something other than Unsat, Sat, or Unknown.";
            None)

let synthesize_lemmas ~(p : psi_def) synt_failure_info (lstate : refinement_loop_state) :
    (refinement_loop_state, solver_response) Result.t =
  (*
    Example: the synt_failure_info should be a list of unrealizability counterexamples, which
    are pairs of counterexamples.
    Each counterexample can be classfied as positive or negative w.r.t to the predicate p.psi_tinv.
    The lemma corresponding to a particular term should be refined to eliminate the counterexample
    (a counterexample cex is also asscociated to a particular term through cex.ctex_eqn.eterm)
   *)
  let new_state, success =
    match synt_failure_info with
    | _, Either.Second unrealizability_ctexs ->
        (* Forget about the specific association in pairs. *)
        let ctexs = List.concat_map unrealizability_ctexs ~f:(fun uc -> [ uc.ci; uc.cj ]) in
        (* Classify in negative and positive cexs. *)
        let positive_ctexs, negative_ctexs, _ = classify_ctexs_opt ~p ctexs in
        let ts : term_state =
          update_term_state_for_ctexs ~p lstate.term_state ~neg_ctexs:negative_ctexs
            ~pos_ctexs:positive_ctexs
        in
        if List.is_empty negative_ctexs then (ts, false)
        else
          Map.fold ts
            ~init:(Map.empty (module Terms), true)
            ~f:(fun ~key ~data:det (acc, status) ->
              if not status then (acc, status)
              else
                match lemma_refinement_loop det ~p with
                | None -> (acc, false)
                | Some det -> (Map.add_exn ~key ~data:det acc, status))
    | _ -> failwith "There is no synt_failure_info in synthesize_lemmas."
  in
  if
    success
    || !Config.interactive_lemmas_loop
       &&
       (Log.info (fun frmt () -> Fmt.pf frmt "No luck. Try again? (Y/N)");
        match Stdio.In_channel.input_line Stdio.stdin with
        | None | Some "" | Some "N" -> false
        | Some "Y" -> true
        | _ -> false)
  then Ok { lstate with term_state = new_state }
  else
    match synt_failure_info with
    | RFail, _ ->
        Log.error_msg "SyGuS solver failed to find a solution.";
        Error RFail
    | RInfeasible, _ ->
        (* Rare - but the synthesis solver can answer "infeasible", in which case it can give
           counterexamples. *)
        Log.info
          Fmt.(
            fun frmt () ->
              pf frmt "@[<hov 2>This problem has no solution. Counterexample set:@;%a@]"
                (list ~sep:sp pp_term) (Set.elements lstate.t_set));
        Error RInfeasible
    | RUnknown, _ ->
        (* In most cases if the synthesis solver does not find a solution and terminates, it will
           answer unknowns. We interpret it as "no solution can be found". *)
        Log.error_msg "SyGuS solver returned unknown.";
        Error RUnknown
    | s_resp, _ -> Error s_resp
