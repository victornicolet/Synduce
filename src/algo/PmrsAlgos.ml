open Base
open Lang.PMRScheme
open Lang.Term
open Lang.Analysis

let mgt_of_one (prog : pmrs) (_ : int) (rule_id : int) =
  let get_rule i =
    match Map.find prog.prules i with
    | Some r -> r
    | None -> failwith (Fmt.str "mgt_of_one : could not find rule %i" i)
  in
  let boundvars = ref (VarSet.union_list [prog.pnon_terminals; prog.pparams]) in
  let unbound x =
    Set.diff (free_variables x) !boundvars
  in
  (* Find a rule, such that the rhs has a subexpression that can be unified with target. *)
  let matching_rules visited_rules target =
    let filter ~key ~data:(nt,args,pat,r_rhs) =
      if Set.mem visited_rules key then None else
        (match matches_subpattern ~boundvars:!boundvars target ~pattern:r_rhs with
         | Some (_, substs, _) ->
           let lhs, _ =
             match pat with
             | Some (cstr, pat_args) ->
               let pat_arg = mk_data cstr pat_args in
               infer_type (mk_app (mk_var nt) (List.map ~f:mk_var args @ [pat_arg]))
             | None ->
               infer_type (mk_app (mk_var nt) (List.map ~f:mk_var args))
           in
           let target' = substitution substs lhs in
           let t_free = unbound target' in
           let new_symbols, new_target = mk_with_fresh_vars t_free target' in
           boundvars := Set.union new_symbols !boundvars;
           Some (nt, new_target)

         | None -> None)
    in
    Map.filter_mapi ~f:filter prog.prules
  in
  (* Recursive construction of the MGT. *)
  let rec aux visited_rules target_rhs =
    let all_mrules = Map.to_alist (matching_rules visited_rules target_rhs) in
    match all_mrules with
    | (m_id, (m_nt, m_term)) :: _ ->
      if Variable.(m_nt = prog.pmain_symb) then
        m_term
      else
        aux (Set.add visited_rules m_id) m_term
    | [] -> failwith (Fmt.str "No matching rule for %a." pp_term target_rhs)
  in
  let init_term =
    let _, _, _, init_t =
      get_rule rule_id
    in
    let new_symbols, new_term =
      mk_with_fresh_vars
        (unbound init_t)
        init_t
    in
    boundvars := Set.union !boundvars new_symbols;
    new_term
  in
  aux (Set.empty (module Int)) init_term

let mgt (prog : pmrs) : term list =
  let xi = prog.pparams in
  (* A map from xi.id to rule.id *)
  let xi_to_rule =
    let xim =
      match
        Map.of_alist (module Int)
          (List.map ~f:(fun v -> (v.vid, [])) (VarSet.elements xi))
      with
      | `Duplicate_key _ -> failwith "impossible"
      | `Ok xmap -> xmap
    in
    let f ~key:rule_id ~data:(_,_,_,rule_rhs) acc =
      let rule_unknowns =
        Set.inter xi (free_variables rule_rhs)
      in
      List.fold ~init:acc
        ~f:(fun xmap xi -> Map.add_multi xmap ~key:xi.vid ~data:rule_id)
        (Set.elements rule_unknowns)
    in
    Map.fold ~init:xim ~f prog.prules
  in
  (* For each pair of xi.id, rule.id, compute the mgt. *)
  let xi_rule_pairs =
    Map.fold ~init:[]
      ~f:(fun ~key ~data acc -> acc @ (List.map ~f:(fun rid -> key, rid) data))
      xi_to_rule
  in
  List.map ~f:(fun (xi_id, rule_id) -> mgt_of_one prog xi_id rule_id) xi_rule_pairs


let most_general_terms (prog : pmrs) : term list =
  if Set.is_empty prog.pparams then [] else mgt prog