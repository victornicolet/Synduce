val log_proc_start : int -> unit
val log_proc_restart : int -> unit
val log_alive : int -> unit
val get_alive : unit -> (string * int) list
val get_solver_pids : unit -> (string * int list) list
val log_proc_quit : ?status:int -> int -> unit
val get_elapsed : int -> float
val glob_start : unit -> unit
val get_glob_elapsed : unit -> float
val verif_time : float ref
val add_verif_time : float -> unit
val log_solver_start : int -> string -> unit
