open Lwt
open AState
open Base
open Lang
open Term
open Utils
open Smtlib
open SmtInterface
module Solvers = SyncSmt
open Syguslib.Sygus
open SygusInterface
module S = Smtlib.SmtLib

let _NUM_POSIIVE_EXAMPLES_ = 30
let _POSITIVE_EXAMPLES_ : (int, term list) Hashtbl.t = Hashtbl.create (module Int) ~size:5

let add_positive_example (f : Variable.t) (ex : term) : unit =
  Hashtbl.add_multi ~key:f.vid ~data:ex _POSITIVE_EXAMPLES_
;;

let get_positive_examples (f : Variable.t) : term list =
  Hashtbl.find_multi _POSITIVE_EXAMPLES_ f.vid
;;

(** Generate positive examples for the input PMRS, using a SMT solver to find
  different possible outputs.
  *)
let gen_pmrs_positive_examples (p : PMRS.t) =
  let ref_typ_out = List.last_exn p.pinput_typ in
  let reference t = Reduce.reduce_term (Reduce.reduce_pmrs p t) in
  let out_term = mk_composite_base_type !_alpha in
  let atoms = Analysis.free_variables out_term in
  let iterations = ref 0 in
  let z3 = Solvers.make_z3_solver () in
  Solvers.load_min_max_defs z3;
  Solvers.declare_all
    z3
    (List.map ~f:snd (SmtInterface.declare_datatype_of_rtype !_alpha));
  Solvers.declare_all z3 (decls_of_vars atoms);
  let mk_ex _ t =
    let t' = reference t in
    let fv = Analysis.free_variables t' in
    Solvers.spush z3;
    Solvers.declare_all z3 (decls_of_vars fv);
    Solvers.smt_assert z3 (smt_of_term (mk_bin Binop.Eq t' out_term));
    let resp =
      match Solvers.check_sat z3 with
      | SmtLib.Sat ->
        (* SAT: get the model. *)
        let mmap = model_to_varmap atoms (Solvers.get_model z3) in
        let value = Eval.in_model mmap out_term in
        (* Add the positive example for the current function. *)
        add_positive_example p.pvar value;
        (* Pop the current stack. *)
        Solvers.spop z3;
        (* Make the values forbidden in subsequent solver calls. *)
        Solvers.smt_assert
          z3
          SmtLib.(mk_not (mk_eq (smt_of_term out_term) (smt_of_term value)));
        SmtLib.Sat
      | _ as t ->
        (* UNSAT: the loop will stop, but pop the current stack before.  *)
        Solvers.spop z3;
        t
    in
    resp
  in
  let _ =
    Expand.expand_loop
      iterations (* Stop at _NUM_POSITIVES_EXAMEPLES_ examples. *)
      ~r_stop:(fun _ -> !iterations > _NUM_POSIIVE_EXAMPLES_)
      mk_ex
      (TermSet.singleton (mk_var (Variable.mk ~t:(Some ref_typ_out) (Alpha.fresh ()))))
  in
  Solvers.close_solver z3;
  get_positive_examples p.pvar
;;

let set_up_bounded_solver (logic : string) (vars : VarSet.t) solver =
  let%lwt () = SmtInterface.AsyncSmt.set_logic solver logic in
  let%lwt () = SmtInterface.AsyncSmt.set_option solver "produce-models" "true" in
  let%lwt () = SmtInterface.AsyncSmt.set_option solver "incremental" "true" in
  let%lwt () =
    if !Config.induction_proof_tlimit >= 0
    then
      SmtInterface.AsyncSmt.set_option
        solver
        "tlimit"
        (Int.to_string !Config.induction_proof_tlimit)
    else return ()
  in
  let%lwt () = SmtInterface.AsyncSmt.load_min_max_defs solver in
  let%lwt () =
    SmtInterface.AsyncSmt.declare_all solver (SmtInterface.decls_of_vars vars)
  in
  return ()
;;

let smt_of_aux_ensures ~(p : psi_def) : S.smtTerm list =
  let mk_sort maybe_rtype =
    match maybe_rtype with
    | None -> S.mk_int_sort
    | Some rtype -> SmtInterface.sort_of_rtype rtype
  in
  let pmrss : PMRS.t list =
    [ p.psi_reference; p.psi_target; p.psi_reference ]
    @
    match p.psi_tinv with
    | None -> []
    | Some tinv -> [ tinv ]
  in
  let vars : variable list =
    List.concat
      (List.map
         ~f:(fun (pmrs : PMRS.t) ->
           List.filter
             ~f:(fun v ->
               (not Variable.(v = pmrs.pmain_symb)) && not Variable.(v = pmrs.pvar))
             (Set.elements pmrs.pnon_terminals))
         pmrss)
  in
  List.fold
    ~init:[]
    ~f:(fun acc v ->
      let maybe_ens = Specifications.get_ensures v in
      match maybe_ens with
      | None -> acc
      | Some t ->
        let arg_types = fst (RType.fun_typ_unpack (Variable.vtype_or_new v)) in
        let arg_vs =
          List.map ~f:(fun t -> Variable.mk ~t:(Some t) (Alpha.fresh ())) arg_types
        in
        let args = List.map ~f:mk_var arg_vs in
        let quants =
          List.map
            ~f:(fun var -> S.SSimple var.vname, mk_sort (Variable.vtype var))
            arg_vs
        in
        let ens = Reduce.reduce_term (mk_app t [ mk_app_v v args ]) in
        let smt = S.mk_forall quants (SmtInterface.smt_of_term ens) in
        smt :: acc)
    vars
;;

let smt_of_ensures_validity ~(p : psi_def) (ensures : term) =
  let mk_sort maybe_rtype =
    match maybe_rtype with
    | None -> S.mk_int_sort
    | Some rtype -> SmtInterface.sort_of_rtype rtype
  in
  let f_compose_r t =
    let repr_of_v =
      if p.psi_repr_is_identity then t else Reduce.reduce_pmrs p.psi_repr t
    in
    Reduce.reduce_term (Reduce.reduce_pmrs p.psi_reference repr_of_v)
  in
  let t = List.last_exn p.psi_repr.pinput_typ in
  let quants = [ S.SSimple "t", mk_sort (Some t) ] in
  let ensures_app =
    SmtInterface.smt_of_term
      (mk_app ensures [ f_compose_r (mk_var (Variable.mk "t" ~t:(Some t))) ])
  in
  [ S.mk_assert (S.mk_not (S.mk_forall quants ensures_app)) ]
;;

let set_up_to_get_ensures_model solver ~(p : psi_def) (ensures : term) =
  let t = List.last_exn p.psi_repr.pinput_typ in
  let var = Variable.mk "t" ~t:(Some t) in
  let f_compose_r t =
    let repr_of_v =
      if p.psi_repr_is_identity then t else Reduce.reduce_pmrs p.psi_repr t
    in
    Reduce.reduce_term (Reduce.reduce_pmrs p.psi_reference repr_of_v)
  in
  let%lwt () =
    SmtInterface.AsyncSmt.declare_all
      solver
      (SmtInterface.decls_of_vars (VarSet.singleton var))
  in
  let ensures_app =
    SmtInterface.smt_of_term
      (mk_app ensures [ f_compose_r (mk_var (Variable.mk "t" ~t:(Some t))) ])
  in
  SmtInterface.AsyncSmt.exec_command solver (S.mk_assert (S.mk_not ensures_app))
;;

let handle_ensures_synth_response
    ((task, resolver) : solver_response option Lwt.t * int Lwt.u)
    (var : variable)
  =
  let parse_synth_fun (fname, _fargs, _, fbody) =
    let body, _ =
      infer_type (term_of_sygus (VarSet.to_env (VarSet.of_list [ var ])) fbody)
    in
    fname, [], body
  in
  match
    Lwt_main.run
      (Lwt.wakeup resolver 0;
       task)
  with
  | Some (RSuccess resps) ->
    let soln = List.map ~f:parse_synth_fun resps in
    Some soln
  | Some RInfeasible | Some RFail | Some RUnknown | None -> None
;;

let make_ensures_name (id : int) = "ensures_" ^ Int.to_string id

let synthfun_ensures ~(p : psi_def) (id : int) : command * variable * string =
  let var = Variable.mk ~t:(Some p.psi_reference.poutput_typ) (Alpha.fresh ()) in
  let params = [ var.vname, sort_of_rtype p.psi_reference.poutput_typ ] in
  let ret_sort = sort_of_rtype RType.TBool in
  let opset =
    List.fold
      ~init:OpSet.empty
      ~f:(fun acc func -> Set.union acc (Analysis.operators_of func.f_body))
      (PMRS.func_of_pmrs p.psi_reference
      @ PMRS.func_of_pmrs p.psi_repr
      @
      match p.psi_tinv with
      | None -> []
      | Some pmrs -> PMRS.func_of_pmrs pmrs)
  in
  (* OpSet.of_list [ Binary Binop.Mod ] in *)
  let grammar = Grammars.generate_grammar ~guess:None ~bools:true opset params ret_sort in
  let logic = dt_extend_base_logic (logic_of_operators opset) in
  CSynthFun (make_ensures_name id, params, ret_sort, grammar), var, logic
;;

let constraint_of_neg (id : int) ~(p : psi_def) (ctex : ctex) : command =
  ignore p;
  let params =
    List.concat_map
      ~f:(fun (_, elimv) -> [ Eval.in_model ctex.ctex_model elimv ])
      ctex.ctex_eqn.eelim
  in
  CConstraint
    (SyApp
       ( IdSimple "not"
       , [ SyApp (IdSimple (make_ensures_name id), List.map ~f:sygus_of_term params) ] ))
;;

let set_up_ensures_solver solver ~(p : psi_def) (ensures : term) =
  ignore ensures;
  let%lwt () = SmtInterface.AsyncSmt.set_logic solver "ALL" in
  let%lwt () = SmtInterface.AsyncSmt.set_option solver "quant-ind" "true" in
  let%lwt () = SmtInterface.AsyncSmt.set_option solver "produce-models" "true" in
  let%lwt () = SmtInterface.AsyncSmt.set_option solver "incremental" "true" in
  let%lwt () =
    if !Config.induction_proof_tlimit >= 0
    then
      SmtInterface.AsyncSmt.set_option
        solver
        "tlimit"
        (Int.to_string !Config.induction_proof_tlimit)
    else return ()
  in
  let%lwt () = SmtInterface.AsyncSmt.load_min_max_defs solver in
  let%lwt () =
    Lwt_list.iter_p
      (fun x ->
        let%lwt _ = SmtInterface.AsyncSmt.exec_command solver x in
        return ())
      ((match p.psi_tinv with
       | None -> []
       | Some tinv -> SmtInterface.smt_of_pmrs tinv)
      @ (if p.psi_repr_is_identity
        then SmtInterface.smt_of_pmrs p.psi_reference
        else
          SmtInterface.smt_of_pmrs p.psi_reference @ SmtInterface.smt_of_pmrs p.psi_repr)
      (* Assert invariants on functions *)
      @ List.map ~f:S.mk_assert (smt_of_aux_ensures ~p))
  in
  return ()
;;

let constraint_of_pos (id : int) (term : term) : command =
  CConstraint (SyApp (IdSimple (make_ensures_name id), [ sygus_of_term term ]))
;;

let verify_ensures_unbounded ~(p : psi_def) (ensures : term)
    : SmtInterface.AsyncSmt.response * int Lwt.u
  =
  let build_task (cvc4_instance, task_start) =
    let%lwt _ = task_start in
    let%lwt () = set_up_ensures_solver cvc4_instance ~p ensures in
    let%lwt () =
      (Lwt_list.iter_p (fun x ->
           let%lwt _ = SmtInterface.AsyncSmt.exec_command cvc4_instance x in
           return ()))
        (smt_of_ensures_validity ~p ensures)
    in
    let%lwt resp = SmtInterface.AsyncSmt.check_sat cvc4_instance in
    let%lwt final_response =
      match resp with
      | Sat | Unknown ->
        let%lwt _ = set_up_to_get_ensures_model cvc4_instance ~p ensures in
        let%lwt resp' = SmtInterface.AsyncSmt.check_sat cvc4_instance in
        (match resp' with
        | Sat | Unknown -> SmtInterface.AsyncSmt.get_model cvc4_instance
        | _ -> return resp')
      | _ -> return resp
    in
    let%lwt () = SmtInterface.AsyncSmt.close_solver cvc4_instance in
    Log.debug_msg "Unbounded ensures verification is complete.";
    return final_response
  in
  SmtInterface.AsyncSmt.(
    cancellable_task (SmtInterface.AsyncSmt.make_cvc_solver ()) build_task)
;;

let verify_ensures_bounded ~(p : psi_def) (ensures : term) (var : variable)
    : SmtInterface.AsyncSmt.response * int Lwt.u
  =
  let base_term =
    mk_var (Variable.mk "t" ~t:(Some (List.last_exn p.psi_repr.pinput_typ)))
  in
  let task (solver, starter) =
    let%lwt _ = starter in
    let%lwt _ = set_up_bounded_solver "DTLIA" VarSet.empty solver in
    let steps = ref 0 in
    let rec check_bounded_sol accum terms =
      let f accum t =
        let%lwt _ = accum in
        let rec_instantation =
          Option.value ~default:VarMap.empty (Analysis.matches t ~pattern:base_term)
        in
        let f_compose_r t =
          let repr_of_v =
            if p.psi_repr_is_identity then t else Reduce.reduce_pmrs p.psi_repr t
          in
          Reduce.reduce_term (Reduce.reduce_pmrs p.psi_reference repr_of_v)
        in
        let%lwt _ =
          SmtInterface.AsyncSmt.declare_all
            solver
            (SmtInterface.decls_of_vars (VarSet.singleton var))
        in
        let%lwt () = SmtInterface.AsyncSmt.spush solver in
        let%lwt _ =
          SmtInterface.AsyncSmt.declare_all
            solver
            (SmtInterface.decls_of_vars
               (VarSet.of_list
                  (List.concat_map
                     ~f:(fun t -> Set.to_list (Analysis.free_variables t))
                     (Map.data rec_instantation))))
        in
        let instance_equals =
          smt_of_term
            (Reduce.reduce_term
               (mk_bin Binop.Eq (mk_var var) (Reduce.reduce_term (f_compose_r t))))
        in
        let%lwt _ = SmtInterface.AsyncSmt.smt_assert solver instance_equals in
        (* Assert that TInv is true for this concrete term t *)
        let%lwt _ =
          match p.psi_tinv with
          | None -> return ()
          | Some tinv ->
            let tinv_t = Reduce.reduce_pmrs tinv t in
            let%lwt _ =
              SmtInterface.AsyncSmt.declare_all
                solver
                (SmtInterface.decls_of_vars (Analysis.free_variables tinv_t))
            in
            let%lwt _ =
              SmtInterface.AsyncSmt.smt_assert solver (SmtInterface.smt_of_term tinv_t)
            in
            return ()
        in
        (* Assert that ensures is false for this concrete term t  *)
        let ensures_reduc =
          Reduce.reduce_term (mk_app ensures [ Reduce.reduce_term (f_compose_r t) ])
        in
        (* let%lwt _ =
             SmtInterface.AsyncSmt.declare_all solver
               (SmtInterface.decls_of_vars (Analysis.free_variables ensures_reduc))
           in *)
        let%lwt _ =
          SmtInterface.AsyncSmt.exec_command
            solver
            (S.mk_assert (S.mk_not (SmtInterface.smt_of_term ensures_reduc)))
        in
        let%lwt resp = SmtInterface.AsyncSmt.check_sat solver in
        (* Note that I am getting a model after check-sat unknown response. This may not halt.  *)
        let%lwt result =
          match resp with
          | SmtLib.Sat | SmtLib.Unknown ->
            let%lwt model = SmtInterface.AsyncSmt.get_model solver in
            return (Some model)
          | _ -> return None
        in
        let%lwt () = SmtInterface.AsyncSmt.spop solver in
        return (resp, result)
      in
      match terms with
      | [] -> accum
      | t0 :: tl ->
        let%lwt accum' = f accum t0 in
        (match accum' with
        | status, Some model -> return (status, Some model)
        | _ -> check_bounded_sol (return accum') tl)
    in
    let rec expand_loop u =
      match Set.min_elt u, !steps < !Config.num_expansions_check with
      | Some t0, true ->
        let tset, u' = Expand.simple t0 in
        let%lwt check_result =
          check_bounded_sol (return (SmtLib.Unknown, None)) (Set.elements tset)
        in
        steps := !steps + Set.length tset;
        (match check_result with
        | _, Some model ->
          Log.debug_msg
            "Bounded ensures verification has found a counterexample to the ensures \
             candidate.";
          return model
        | _ -> expand_loop (Set.union (Set.remove u t0) u'))
      | None, true ->
        (* All expansions have been checked. *)
        return SmtLib.Unsat
      | _, false ->
        (* Check reached limit. *)
        Log.debug_msg "Bounded ensures verification has reached limit.";
        if !Config.bounded_lemma_check then return SmtLib.Unsat else return SmtLib.Unknown
    in
    let%lwt res = expand_loop (TermSet.singleton base_term) in
    return res
  in
  SmtInterface.AsyncSmt.(cancellable_task (make_cvc_solver ()) task)
;;

let verify_ensures_candidate ~(p : psi_def) (maybe_ensures : term option) (var : variable)
    : SmtInterface.SyncSmt.solver_response
  =
  match maybe_ensures with
  | None -> failwith "Cannot verify ensures candidate; there is none."
  | Some ensures ->
    Log.verbose (fun f () -> Fmt.(pf f "Checking ensures candidate..."));
    let resp =
      try
        Lwt_main.run
          (let pr1, resolver1 = verify_ensures_bounded ~p ensures var in
           let pr2, resolver2 = verify_ensures_unbounded ~p ensures in
           Lwt.wakeup resolver2 1;
           Lwt.wakeup resolver1 1;
           (* The first call to return is kept, the other one is ignored. *)
           Lwt.pick [ pr1; pr2 ])
      with
      | End_of_file ->
        Log.error_msg "Solvers terminated unexpectedly  ⚠️ .";
        Log.error_msg "Please inspect logs.";
        SmtLib.Unknown
    in
    resp
;;

let handle_ensures_verif_response (response : S.solver_response) (ensures : term) =
  match response with
  | Unsat ->
    Log.verbose (fun f () -> Fmt.(pf f "This ensures has been proven correct."));
    Log.info (fun frmt () -> Fmt.pf frmt "Ensures is %a" pp_term ensures);
    true, None
  | SmtLib.SExps x ->
    Log.verbose (fun f () ->
        Fmt.(pf f "This ensures has not been proven correct. Refining ensures..."));
    false, Some x
  | Sat ->
    Log.error_msg "Ensures verification returned Sat, which is weird.";
    false, None
  | Unknown ->
    Log.error_msg "Ensures verification returned Unknown.";
    false, None
  | _ ->
    Log.error_msg "Ensures verification is indeterminate.";
    false, None
;;

let rec synthesize
    ~(p : psi_def)
    (positives : ctex list)
    (negatives : ctex list)
    (prev_positives : term list)
    : term option
  =
  Log.debug_msg "Synthesize predicates..";
  let vals ctex =
    List.iter ctex.ctex_eqn.eelim ~f:(fun (_, elimv) ->
        let tval = Eval.in_model ctex.ctex_model elimv in
        Log.debug_msg
          Fmt.(
            str
              "%a should not be in the image of %s"
              pp_term
              tval
              p.psi_reference.pvar.vname))
  in
  List.iter ~f:vals negatives;
  let new_positives =
    match prev_positives with
    | [] -> gen_pmrs_positive_examples p.psi_reference
    | _ -> prev_positives
  in
  Log.debug
    Fmt.(
      fun fmt () ->
        pf
          fmt
          "These examples are in the image of %s:@;%a"
          p.psi_reference.pvar.vname
          (list ~sep:comma pp_term)
          new_positives);
  let id = 0 in
  let synth_objs, var, logic = synthfun_ensures ~p id in
  let neg_constraints = List.map ~f:(constraint_of_neg id ~p) negatives in
  let pos_constraints = List.map ~f:(constraint_of_pos id) new_positives in
  let extra_defs = [ max_definition; min_definition ] in
  let commands =
    CSetLogic logic
    :: (extra_defs @ [ synth_objs ] @ neg_constraints @ pos_constraints @ [ CCheckSynth ])
  in
  match
    handle_ensures_synth_response (SygusInterface.SygusSolver.solve_commands commands) var
  with
  | None -> None
  | Some solns ->
    let _, _, body = List.nth_exn solns 0 in
    let ensures = mk_fun [ FPatVar var ] (Eval.simplify body) in
    Log.debug_msg Fmt.(str "Ensures candidate is %a." pp_term ensures);
    let var = Variable.mk ~t:(Some p.psi_reference.poutput_typ) (Alpha.fresh ()) in
    (match
       handle_ensures_verif_response
         (verify_ensures_candidate ~p (Some ensures) var)
         ensures
     with
    | true, _ -> Some ensures
    | false, Some sexprs ->
      let result =
        Map.find (SmtInterface.model_to_constmap (SmtLib.SExps sexprs)) var.vname
      in
      (match result with
      | None ->
        Log.debug_msg "No model found; cannot refine ensures.";
        None
      | Some r ->
        Log.debug_msg
          Fmt.(str "The counterexample to the ensures candidate is %a" pp_term r);
        synthesize ~p positives negatives (r :: new_positives))
    | false, _ -> None)
;;
