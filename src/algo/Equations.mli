open Base
open Lang

val compute_preconds
  :  p:AState.psi_def
  -> term_state:AState.term_state
  -> (Term.term -> Term.term)
  -> Term.term
  -> Term.term option

val filter_elims : (Term.term * 'a) list -> Term.term -> (Term.term * 'a) list

val make
  :  ?force_replace_off:bool
  -> p:AState.psi_def
  -> term_state:AState.term_state
  -> lifting:AState.lifting
  -> Term.TermSet.t
  -> AState.equation list * AState.lifting

val revert_projs
  :  Term.VarSet.t
  -> (int, Term.variable list, Int.comparator_witness) Map.t
  -> (string * Term.variable list * Term.term) list
  -> (string * Term.variable list * Term.term) list

val free_vars_of_equations : AState.equation list -> Term.VarSet.t

type partial_soln = (string * Term.variable list * Term.term) list

val pp_partial_soln
  :  Formatter.t
  -> (string * Term.variable list * Term.term) list
  -> unit

val solve
  :  p:AState.psi_def
  -> AState.equation list
  -> Syguslib.Sygus.solver_response
     * (partial_soln, Counterexamples.unrealizability_ctex list) Either.t

val update_assumptions
  :  p:AState.psi_def
  -> AState.refinement_loop_state
  -> partial_soln
  -> Term.TermSet.t
  -> AState.refinement_loop_state
