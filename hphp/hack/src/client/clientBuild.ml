(**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* 800s was chosen because it was above most of the historical p95 of
 * hack server startup times as observed here:
 * https://fburl.com/48825801, see also https://fburl.com/29184831 *)
let num_build_retries = 800

type env = {
  root : Path.path;
  build_opts : ServerMsg.build_opts;
}

let should_retry env tries = env.build_opts.ServerMsg.wait || tries > 0

let rec connect env retries =
  try
    let result = ClientUtils.connect env.root in
    if Tty.spinner_used() then Tty.print_clear_line stdout;
    result
  with
  | ClientExceptions.Server_cant_connect ->
    Printf.printf "Can't connect to server yet, retrying.\n%!";
    if should_retry env retries
    then begin
      Unix.sleep 1;
      connect env (retries - 1)
    end
    else exit 2
  | ClientExceptions.Server_initializing ->
    let wait_msg = if env.build_opts.ServerMsg.wait
                   then Printf.sprintf "will wait forever due to --wait option, have waited %d seconds" (num_build_retries - retries)
                   else Printf.sprintf "will wait %d more seconds" retries in
    Printf.printf
      (* This extra space before the \r is here to erase the spinner
         when the length of this line decreases (but by at most 1!) as
         it ticks down. We don't want to rely on Tty.print_clear_line
         --- it would emit newlines when stdout is not a tty, and
         obviate the effect of the \r. *)
      "Hack server still initializing. (%s) %s \r%!"
      wait_msg (Tty.spinner());
    if should_retry env retries
    then begin
      Unix.sleep 1;
      connect env (retries - 1)
    end
    else begin
      if Tty.spinner_used() then Tty.print_clear_line stdout;
      Printf.printf "Waited >%ds for hack server initialization.\n%s\n%s\n%s\n%!"
        num_build_retries
        "Your hack server is still initializing. This is an IO-bound"
        "operation and may take a while if your disk cache is cold."
        "Trying the build again may work; the server may be caught up now.";
      exit 2
    end

let rec wait_for_response ic =
  try Utils.with_context
    ~enter:(fun () ->
      Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ ->
        raise ClientExceptions.Server_busy));
      ignore (Unix.alarm 1))
    ~exit:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm Sys.Signal_default)
    ~do_:(fun () ->
      let response = ServerMsg.response_from_channel ic in
      if Tty.spinner_used() then Tty.print_clear_line stdout;
      response)
  with
  | End_of_file ->
     prerr_string "Server disconnected or crashed. Try `hh_client restart`\n";
     flush stderr;
     exit 1
  | ClientExceptions.Server_busy ->
     (* We timed out waiting for response from hh_server, update message *)
     Printf.printf
       "Awaiting response from hh_server, hh_server typechecking... %s \r%!"
       (Tty.spinner());
     wait_for_response ic

let rec main_ env retries =
  (* Check if a server is up *)
  if not (ClientUtils.server_exists env.root)
  then ClientStart.start_server { ClientStart.
    root = env.root;
    wait = false;
    no_load = false;
  };
  let ic, oc = connect env retries in
  ServerMsg.cmd_to_channel oc (ServerMsg.BUILD env.build_opts);
  let response = wait_for_response ic in
  match response with
  | ServerMsg.SERVER_OUT_OF_DATE ->
    Printf.printf
      "Hack server is an old version, trying again.\n%!";
    Unix.sleep 2;
    main_ env (retries - 1)
  | ServerMsg.PONG -> (* successful case *)
    begin
      let finished = ref false in
      let exit_code = ref 0 in
      EventLogger.client_begin_work (ClientLogCommand.LCBuild
        (env.root, env.build_opts.ServerMsg.incremental));
      try
        while true do
          let line:ServerMsg.build_progress = Marshal.from_channel ic in
          match line with
          | ServerMsg.BUILD_PROGRESS s -> print_endline s
          | ServerMsg.BUILD_ERROR s -> exit_code := 2; print_endline s
          | ServerMsg.BUILD_FINISHED -> finished := true
        done
      with End_of_file ->
        if not !finished then begin
          Printf.fprintf stderr ("Build unexpectedly terminated! "^^
            "You may need to do `hh_client restart`.\n");
          exit 1
        end;
        if !exit_code = 0
        then ()
        else exit (!exit_code)
    end
  | resp -> Printf.printf "Unexpected server response %s.\n%!"
    (ServerMsg.response_to_string resp)

let main env =
  main_ env num_build_retries
