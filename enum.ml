(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Consumable generators} *)

exception EOG
  (** End of Generation *)

type 'a t = unit -> 'a generator
  (** An enum is a generator of generators *)
and 'a generator = unit -> 'a
  (** A generator may be called several times, yielding the next value
      each time. It raises EOG when it reaches the end. *)

(** {2 Generator functions} *)

let start enum = enum ()

module Gen = struct
  let next gen = gen ()

  let junk gen = ignore (gen ())

  let rec fold f acc gen =
    let acc', stop =
      try f acc (gen ()), false
      with EOG -> acc, true in
    if stop then acc' else fold f acc' gen

  let rec iter f gen =
    let stop =
      try f (gen ()); false
      with EOG -> true in
    if stop then () else iter f gen

  let length gen =
    fold (fun acc _ -> acc + 1) 0 gen
end

(** {2 Basic constructors} *)

let empty () = fun () -> raise EOG

let singleton x =
  fun () ->
    let stop = ref false in
    fun () ->
      if !stop
        then raise EOG
        else begin stop := true; x end

let repeat x =
  let f () = x in
  fun () -> f

(** [iterate x f] is [[x; f x; f (f x); f (f (f x)); ...]] *)
let iterate x f =
  fun () ->
    let acc = ref x in
    fun () ->
      let cur = !acc in
      acc := f cur;
      cur

(** {2 Basic combinators} *)

let is_empty enum =
  try ignore ((enum ()) ()); false
  with EOG -> true

let fold f acc enum =
  Gen.fold f acc (enum ())

let iter f enum =
  Gen.iter f (enum ())

let length enum =
  Gen.length (enum ())
              
let map f enum =
  (* another enum *)
  fun () ->
    let gen = enum () in
    (* the mapped generator *)
    fun () ->
      try f (gen ())
      with EOG -> raise EOG

let append e1 e2 =
  fun () ->
    let gen = ref (e1 ()) in
    let first = ref true in
    (* get next element *)
    let rec next () =
      try !gen ()
      with EOG ->
        if !first then begin
          first := false;
          gen := e2 ();  (* switch to the second generator *)
          next ()
        end else raise EOG  (* done *)
    in next

let cycle enum =
  assert (not (is_empty enum));
  fun () ->
    let gen = ref (enum ()) in
    let rec next () =
      try !gen ()
      with EOG ->
        gen := enum ();
        next ()
    in next

let flatten enum =
  fun () ->
    let next_gen = enum () in
    let gen = ref (fun () -> raise EOG) in
    (* get next element *)
    let rec next () =
      try !gen ()
      with EOG ->
        (* jump to next sub-enum *)
        let stop =
          try gen := (next_gen () ()); false
          with EOG -> true in
        if stop then raise EOG else next ()
    in next
      
let flatMap f enum =
  fun () ->
    let next_elem = enum () in
    let gen = ref (fun () -> raise EOG) in
    (* get next element *)
    let rec next () =
      try !gen ()
      with EOG ->
        (* enumerate f (next element) *)
        let stop =
          try
            let x = next_elem () in
            gen := (f x) (); false
          with EOG -> true in
        if stop then raise EOG else next ()
    in next

let take n enum =
  assert (n >= 0);
  fun () ->
    let gen = enum () in
    let count = ref 0 in  (* how many yielded elements *)
    fun () ->
      if !count = n then raise EOG
      else begin incr count; gen () end

let drop n enum =
  assert (n >= 0);
  fun () ->
    let gen = enum () in
    let count = ref 0 in  (* how many droped elements? *)
    let rec next () =
      if !count < n
        then begin incr count; ignore (gen ()); next () end
        else gen ()
    in next

let filter p enum =
  fun () ->
    let gen = enum () in
    let rec next () =
      match (try Some (gen ()) with EOG -> None) with
      | None -> raise EOG
      | Some x ->
        if p x
          then x (* yield element *)
          else next ()  (* discard element *)
    in next

let takeWhile p enum =
  fun () ->
    let gen = enum () in
    let rec next () =
      match (try Some (gen ()) with EOG -> None) with
      | None -> raise EOG
      | Some x ->
        if p x
          then x (* yield element *)
          else raise EOG (* stop *)
    in next

let dropWhile p enum =
  fun () ->
    let gen = enum () in
    let stop_drop = ref false in
    let rec next () =
      match (try Some (gen ()) with EOG -> None) with
      | None -> raise EOG
      | Some x when !stop_drop -> x (* yield *)
      | Some x ->
        if p x
          then next ()  (* drop *)
          else (stop_drop := true; x) (* stop dropping, and yield *)
    in next

let filterMap f enum =
  fun () ->
    let gen = enum () in
    (* tailrec *)
    let rec next () =
      match (try Some (gen ()) with EOG -> None) with
      | None -> raise EOG
      | Some x ->
        begin
          match f x with
          | None -> next ()  (* drop element *)
          | Some y -> y  (* return [f x] *)
        end
    in next

let zipWith f a b =
  fun () ->
    let gen_a = a () in
    let gen_b = b () in
    fun () ->
      f (gen_a ()) (gen_b ())

let zip a b = zipWith (fun x y -> x,y) a b

let zipIndex enum =
  fun () ->
    let r = ref 0 in
    let gen = enum () in
    fun () ->
      let x = gen () in
      let n = !r in
      incr r;
      n, x

(** {2 Complex combinators} *)

(** Pick elements fairly in each sub-enum *)
let round_robin enum =
  (* list of sub-enums *)
  let l = fold (fun acc x -> x::acc) [] enum in
  let l = List.rev l in
  fun () ->
    let q = Queue.create () in
    List.iter (fun enum' -> Queue.push (enum' ()) q) l;
    (* recursive function to get next element *)
    let rec next () =
      if Queue.is_empty q
        then raise EOG
        else
          let gen = Queue.pop q in
          match (try Some (gen ()) with EOG -> None) with
          | None -> next ()  (* exhausted generator, drop it *)
          | Some x ->
            Queue.push gen q; (* put generator at the end, return x *)
            x
    in next

(** {3 Mutable double-linked list, similar to {! Deque.t} *)
module MList = struct
  type 'a t = 'a node option ref
  and 'a node = {
    content : 'a;
    mutable prev : 'a node;
    mutable next : 'a node;
  }

  let create () = ref None

  let is_empty d =
    match !d with
    | None -> true
    | Some _ -> false

  let push_back d x =
    match !d with
    | None ->
      let rec elt = {
        content = x; prev = elt; next = elt; } in
      d := Some elt
    | Some first ->
      let elt = { content = x; next=first; prev=first.prev; } in
      first.prev.next <- elt;
      first.prev <- elt

  (* conversion to enum *)
  let to_enum d =
    fun () ->
      match !d with
      | None -> (fun () -> raise EOG)
      | Some first ->
        let cur = ref first in (* current elemnt of the list *)
        let stop = ref false in (* are we done yet? *)
        (fun () ->
          (if !stop then raise EOG);
          let x = (!cur).content in
          cur := (!cur).next;
          (if !cur == first then stop := true); (* EOG, we made a full cycle *)
          x)
end

(** Store content of the generator in an enum *)
let persistent gen =
  let l = MList.create () in
  (try
    while true do MList.push_back l (gen ()); done
  with EOG ->
    ());
  (* done recursing through the generator *)
  MList.to_enum l

let tee ?(n=2) enum =
  fun () ->
    (* array of queues, together with their index *)
    let qs = Array.init n (fun i -> Queue.create ()) in
    let gen = enum () in  (* unique generator! *)
    let cur = ref 0 in
    (* get next element for the i-th queue *)
    let rec next i =
      let q = qs.(i) in
      if Queue.is_empty q
        then update_to_i i  (* consume generator *)
        else Queue.pop q
    (* consume [gen] until some element for [i]-th generator is
       available. It raises EOG if [gen] is exhausted before *)
    and update_to_i i =
      let x = gen () in
      let j = !cur in
      cur := (j+1) mod n;  (* move cursor to next generator *)
      let q = qs.(j) in
      if j = i
        then begin
          assert (Queue.is_empty q);
          x  (* return the element *)
        end else begin
          Queue.push x q;
          update_to_i i  (* continue consuming [gen] *)
        end
    in
    (* generator of generators *)
    let i = ref 0 in
    fun () ->
      let j = !i in
      if j = n then raise EOG else (incr i; fun () -> next j)

(** Yield elements from a and b alternatively *)
let interleave a b =
  fun () ->
    let gen_a = a () in
    let gen_b = b () in
    let left = ref true in  (* left or right? *)
    fun () ->
      if !left
        then (left := false; gen_a ())
        else (left := true; gen_b ())

(** Put [x] between elements of [enum] *)
let intersperse x enum =
  fun () ->
    let next_elem = ref None in
    let gen = enum () in
    (* must see whether the gen is empty (first element must be from enum) *)
    try
      next_elem := Some (gen ());
      (* get next element *)
      let rec next () =
        match !next_elem with
        | None -> next_elem := Some (gen ()); x  (* yield x, gen is not exhausted *)
        | Some y -> next_elem := None; y (* yield element of gen *)
      in next
    with EOG ->
      fun () -> raise EOG

(** Cartesian product *)
let product a b =
  fun () ->
    (* [a] is the outer relation *)
    let gen_a = a () in
    try
      (* current element of [a] *)
      let cur_a = ref (gen_a ()) in
      let gen_b = ref (b ()) in
      let rec next () =
        try !cur_a, !gen_b ()
        with EOG ->
          (* gen_b exhausted, get next elem of [a] *)
          cur_a := gen_a ();
          gen_b := b ();
          next ()
      in
      next
    with EOG ->
      raise EOG  (* [a] is empty *)

let permutations enum =
  failwith "not implemented" (* TODO *)

let combinations n enum =
  assert (n >= 0);
  failwith "not implemented" (* TODO *)

let powerSet enum =
  failwith "not implemented"

(** {2 Basic conversion functions} *)

let to_list enum =
  let rec fold gen =
    try
      let x = gen () in
      x :: fold gen
    with EOG -> []
  in fold (enum ())
    
let of_list l =
  fun () ->
    let l = ref l in
    fun () ->
      match !l with
      | [] -> raise EOG
      | x::l' -> l := l'; x

let to_rev_list enum =
  fold (fun acc x -> x :: acc) [] enum

let int_range i j =
  fun () ->
    let r = ref i in
    fun () ->
      let x = !r in
      if x > j then raise EOG
        else begin
          incr r;
          x
        end

module Infix = struct
  let (@@) = append

  let (>>=) e f = flatMap f e

  let (--) = int_range

  let (|>) x f = f x
end