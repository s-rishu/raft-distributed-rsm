defmodule Raft do
  @moduledoc """
  An implementation of the Raft consensus protocol.
  """
  import Emulation, only: [send: 2, timer: 1, now: 0, whoami: 0]
  import Float, only: [ceil: 2]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  require Fuzzers
  require Logger

  defstruct(
    # The list of current proceses.
    view: nil,
    # Current leader.
    current_leader: nil,
    # Time before starting an election.
    min_election_timeout: nil,
    max_election_timeout: nil,
    election_timer: nil,
    # Time between heartbeats from the leader.
    heartbeat_timeout: nil,
    heartbeat_timer: nil,
    # Persistent state on all servers.
    current_term: nil,
    voted_for: nil,
    log: nil,
    # Volatile state on all servers
    commit_index: nil,
    last_applied: nil,
    # Volatile state on leader
    is_leader: nil,
    next_index: nil,
    match_index: nil,
    # The queue we are building using this RSM.
    queue: nil
  )

  @doc """
  Create state for an initial Raft cluster. Each
  process should get an appropriately updated version
  of this state.
  """
  @spec new_configuration(
          [atom()],
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: %Raft{}
  def new_configuration(
        view,
        leader,
        min_election_timeout,
        max_election_timeout,
        heartbeat_timeout
      ) do
    %Raft{
      view: view,
      current_leader: leader,
      min_election_timeout: min_election_timeout,
      max_election_timeout: max_election_timeout,
      heartbeat_timeout: heartbeat_timeout,
      # Start from term 1
      current_term: 1,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      is_leader: false,
      next_index: nil,
      match_index: nil,
      queue: :queue.new()
    }
  end

  # Enqueue an item, this **modifies** the state
  # machine, and should only be called when a log
  # entry is committed.
  @spec enqueue(%Raft{}, any()) :: %Raft{}
  defp enqueue(state, item) do
    %{state | queue: :queue.in(item, state.queue)}
  end

  # Dequeue an item, modifying the state machine.
  # This function should only be called once a
  # log entry has been committed.
  @spec dequeue(%Raft{}) :: {:empty | {:value, any()}, %Raft{}}
  defp dequeue(state) do
    {ret, queue} = :queue.out(state.queue)
    {ret, %{state | queue: queue}}
  end

  @doc """
  Commit a log entry, advancing the state machine. This
  function returns a tuple:
  * The first element is {requester, return value}. Your
    implementation should ensure that the leader who committed
    the log entry sends the return value to the requester.
  * The second element is the updated state.
  """
  @spec commit_log_entry(%Raft{}, %Raft.LogEntry{}) ::
          {{atom() | pid(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_entry(state, entry) do
    case entry do
      %Raft.LogEntry{operation: :nop, requester: r, index: i} ->
        {{r, :ok}, %{state | commit_index: i}}

      %Raft.LogEntry{operation: :enq, requester: r, argument: e, index: i} ->
        {{r, :ok}, %{enqueue(state, e) | commit_index: i}}

      %Raft.LogEntry{operation: :deq, requester: r, index: i} ->
        {ret, state} = dequeue(state)
        {{r, ret}, %{state | commit_index: i}}

      %Raft.LogEntry{} ->
        raise "Log entry with an unknown operation: maybe an empty entry?"

      _ ->
        raise "Attempted to commit something that is not a log entry."
    end
  end

  @doc """
  Commit log at index `index`. This index, which one should read from
  the log entry is assumed to start at 1. This function **does not**
  ensure that commits are processed in order.
  """
  @spec commit_log_index(%Raft{}, non_neg_integer()) ::
          {:noentry | {atom(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_index(state, index) do
    if length(state.log) < index do
      {:noentry, state}
    else
      # Note that entry indexes are all 1, which in
      # turn means that we expect commit indexes to
      # be 1 indexed. Now a list is a reversed log,
      # so what we can do here is simple: 
      # Given 0-indexed index i, length(log) - 1 - i
      # is the ith list element. => length(log) - (i +1),
      # and hence length(log) - index is what we want.
      correct_idx = length(state.log) - index
      commit_log_entry(state, Enum.at(state.log, correct_idx))
    end
  end

  # The next few functions are public so we can test them, see
  # log_test.exs.
  @doc """
  Get index for the last log entry.
  """
  @spec get_last_log_index(%Raft{}) :: non_neg_integer()
  def get_last_log_index(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).index
  end

  @doc """
  Get term for the last log entry.
  """
  @spec get_last_log_term(%Raft{}) :: non_neg_integer()
  def get_last_log_term(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).term
  end

  @doc """
  Check if log entry at index exists.
  """
  @spec logged?(%Raft{}, non_neg_integer()) :: boolean()
  def logged?(state, index) do
    index > 0 && length(state.log) >= index
  end

  @doc """
  Get log entry at `index`.
  """
  @spec get_log_entry(%Raft{}, non_neg_integer()) ::
          :no_entry | %Raft.LogEntry{}
  def get_log_entry(state, index) do
    if index <= 0 || length(state.log) < index do
      :noentry
    else
      correct_idx = length(state.log) - index
      Enum.at(state.log, correct_idx)
    end
  end

  @doc """
  Get log entries starting at index.
  """
  @spec get_log_suffix(%Raft{}, non_neg_integer()) :: [%Raft.LogEntry{}]
  def get_log_suffix(state, index) do
    if length(state.log) < index do
      []
    else
      correct_idx = length(state.log) - index
      Enum.take(state.log, correct_idx + 1)
    end
  end

  @doc """
  Truncate log entry at `index`. This removes log entry
  with index `index` and larger.
  """
  @spec truncate_log_at_index(%Raft{}, non_neg_integer()) :: %Raft{}
  def truncate_log_at_index(state, index) do
    if length(state.log) < index do
      # Nothing to do
      state
    else
      to_drop = length(state.log) - index + 1
      %{state | log: Enum.drop(state.log, to_drop)}
    end
  end

  @doc """
  Add log entries to the log. This adds entries to the beginning
  of the log, we assume that entries are already correctly ordered
  (see structural note about log above.).
  """
  @spec add_log_entries(%Raft{}, [%Raft.LogEntry{}]) :: %Raft{}
  def add_log_entries(state, entries) do
    %{state | log: entries ++ state.log}
  end

  @doc """
  Commit entries until commmit_index.
  """
  @spec commit_entries(%Raft{}) :: %Raft{}
  def commit_entries(state) do
    state = if (state.commit_index > state.last_applied) do
      start_idx = (state.last_applied + 1)
      end_idx = state.commit_index
      state = Enum.reduce((start_idx..end_idx), state, fn log_idx, state ->
        {_, res} = commit_log_index(state, log_idx)
        res
      end)
      # {_, state} = commit_log_index(state, state.commit_index)
      # ##IO.puts("debug 3 #{start_idx} #{end_idx}")
      # IO.inspect(state)
      %{state | last_applied: state.commit_index}
    else state end
    state 
  end

  @doc """
  Try to update the commit index. This does not applies the commit.
  """
  @spec try_to_commit(%Raft{}) :: %Raft{}
  def try_to_commit(state) do
    state = if (get_last_log_index(state) > 0) do
      state = ((state.commit_index + 1)..(get_last_log_index(state)) |> Enum.each(fn(log_idx) ->
        Map.to_list(state.match_index) |> Enum.each(fn(match_idx) ->
          if (elem(match_idx, 1) >= log_idx) && (get_log_entry(state, log_idx).term == state.current_term) do
            state = %{state | commit_index: log_idx} #update commit index to largest possible log index
            state
          end
        end)
      end)
      state
      )
      state
    end
    state
  end

  @doc """
  make_leader changes process state for a process that
  has just been elected leader.
  """
  @spec make_leader(%Raft{}) :: %Raft{
          is_leader: true,
          next_index: map(),
          match_index: map()
        }
  def make_leader(state) do
    log_index = get_last_log_index(state)

    # next_index needs to be reinitialized after each
    # election.
    next_index =
      state.view
      |> Enum.map(fn v -> {v, log_index} end)
      |> Map.new()

    # match_index needs to be reinitialized after each
    # election.
    match_index =
      state.view
      |> Enum.map(fn v -> {v, 0} end)
      |> Map.new()

    %{
      state
      | is_leader: true,
        next_index: next_index,
        match_index: match_index,
        current_leader: whoami()
    }
  end

  @doc """
  make_follower changes process state for a process
  to mark it as a follower.
  """
  @spec make_follower(%Raft{}) :: %Raft{
          is_leader: false
        }
  def make_follower(state) do
    %{state | is_leader: false}
  end

  # update_leader: update the process state with the
  # current leader.
  @spec update_leader(%Raft{}, atom()) :: %Raft{current_leader: atom()}
  defp update_leader(state, who) do
    %{state | current_leader: who}
  end

  # Compute a random election timeout between
  # state.min_election_timeout and state.max_election_timeout.
  # See the paper to understand the reasoning behind having
  # a randomized election timeout.
  @spec get_election_time(%Raft{}) :: non_neg_integer()
  defp get_election_time(state) do
    state.min_election_timeout +
      :rand.uniform(
        state.max_election_timeout -
          state.min_election_timeout
      )
  end

  # Save a handle to the election timer.
  @spec save_election_timer(%Raft{}, reference()) :: %Raft{}
  defp save_election_timer(state, timer) do
    %{state | election_timer: timer}
  end

  # Save a handle to the hearbeat timer.
  @spec save_heartbeat_timer(%Raft{}, reference()) :: %Raft{}
  defp save_heartbeat_timer(state, timer) do
    %{state | heartbeat_timer: timer}
  end

  # Utility function to send a message to all
  # processes other than the caller. Should only be used by leader.
  @spec broadcast_to_others(%Raft{is_leader: true}, any()) :: [boolean()]
  defp broadcast_to_others(state, message) do
    me = whoami()

    state.view
    |> Enum.filter(fn pid -> pid != me end)
    |> Enum.map(fn pid -> send(pid, message) end)
  end

  # This function should cancel the current
  # election timer, and set  a new one. 
  @spec reset_election_timer(%Raft{}) :: %Raft{}
  defp reset_election_timer(state) do
    # Set a new election timer
    if state.election_timer do
      Emulation.cancel_timer(state.election_timer) 
    end
    election_timer = Emulation.timer(get_election_time(state), :election_timeout)
    save_election_timer(state, election_timer)
  end

  # This function should cancel the current
  # hearbeat timer, and set  a new one. 
  @spec reset_heartbeat_timer(%Raft{}) :: %Raft{}
  defp reset_heartbeat_timer(state) do
    # Set a new heartbeat timer.
    if state.heartbeat_timer do
      Emulation.cancel_timer(state.heartbeat_timer) 
    end
    heartbeat_timer = Emulation.timer(state.heartbeat_timeout, :heartbeat_timeout)
    save_heartbeat_timer(state, heartbeat_timer)
  end

  @doc """
  This function transitions a process so it is
  a follower.
  """
  @spec become_follower(%Raft{}) :: no_return()
  def become_follower(state) do
    IO.puts("#{whoami()} is becoming follower.")
    follower(make_follower(reset_election_timer(state)), %{})
  end

  @doc """
  This function implements the state machine for a process
  that is currently a follower.
  """
  @spec follower(%Raft{is_leader: false}, any()) :: no_return()
  def follower(state, extra_state) do
    #commit new entries if last applied < commit index
    state = commit_entries(state)
    receive do
      # Messages that are a part of Raft.
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->

        IO.puts(
          "Follower #{whoami()} Received append entry for term #{term} with leader #{leader_id} " <>
            "(#{leader_commit_index} #{inspect(entries)})"
        )
        #handle newly discovered term or leader
        state = cond do
            (term > state.current_term) -> %{state | current_term: term, current_leader: leader_id, voted_for: nil}
            (term == state.current_term) -> %{state | current_leader: leader_id}
            true -> state 
          end

        state = (
        if entries do
          #handle non empty requests using the following rules
          # 1. Reply false if term < currentTerm (§5.1)
          # 2. Reply false if log doesn’t contain an entry at prevLogIndex
          # whose term matches prevLogTerm (§5.3)
          # 3. If an existing entry conflicts with a new one (same index
          # but different terms), delete the existing entry and all that
          # follow it (§5.3)
          # 4. Append any new entries not already in the log
          # 5. If leaderCommit > commitIndex, set commitIndex =
          # min(leaderCommit, index of last new entry)

          if ((term < state.current_term) || (prev_log_index > get_last_log_index(state)) 
            || (get_last_log_index(state) > 0 && (prev_log_term != get_log_entry(state, prev_log_index).term))) do
            #return Failure
            send(sender,
            %Raft.AppendEntryResponse{
              term: state.current_term, #TODO: doubt
              log_index: prev_log_index,
              success: false
            })
            # #IO.puts("debug 2")
            # IO.inspect(state)
            state
          else
            state = (if (logged?(state, prev_log_index + 1)) do #conflicting entry exists
                      truncate_log_at_index(state, prev_log_index + 1)
                    else state end)
            # #IO.puts("debug 6")
            # IO.inspect(state)
            state = add_log_entries(state, entries)
            # #IO.puts("debug 7")
            # IO.inspect(state)
            state = (
              if (leader_commit_index > state.commit_index) do
                state = %{state | commit_index: min(leader_commit_index, get_last_log_index(state))}
                # #IO.puts("debug 4")
                # IO.inspect(state)
              else state end
            )
            # #IO.puts("debug 8")
            # IO.inspect(state)
            #return Success
            send(sender,
              %Raft.AppendEntryResponse{
                term: state.current_term, #TODO: doubt
                log_index: prev_log_index,
                success: true
              })
            # #IO.puts("debug 5")
            # IO.inspect(state)
            state
          end
        else
          state
        end
        )

        state = reset_election_timer(state)
        follower(state, extra_state)
        
      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an AppendEntryResponse received by
        # a follower.
        IO.puts(
          "Follower #{whoami()} received append entry response #{term}," <>
            " index #{index}, succcess #{inspect(succ)} and did nothing."
        )
        state = if (term > state.current_term) do
          %{state | current_term: term, current_leader: nil, voted_for: nil}
        else state end
        follower(state, extra_state)

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->

        IO.puts(
          "Follower #{whoami()} received RequestVote " <>
            "term = #{term}, candidate = #{candidate}"
        )
        state = if (term > state.current_term) do
          %{state | current_term: term, current_leader: nil, voted_for: nil}
        else state end
        # 1. Reply false if term < currentTerm (§5.1)
        # 2. If votedFor is null or candidateId, and candidate’s log is at
        # least as up-to-date as receiver’s log, grant vote
        
        if (term < state.current_term) do
          #IO.puts("Follower #{whoami()} vote not granted due to term less than curr term to candidate #{candidate}.")
          send(sender,
            %Raft.RequestVoteResponse{
              term: state.current_term,
              granted: false
            })
          follower(state, extra_state)
        end

        if ((!state.voted_for) || (state.voted_for == candidate)) && (last_log_index >= get_last_log_index(state)) do
          send(sender,
            %Raft.RequestVoteResponse{
              term: state.current_term,
              granted: true
            })
            state = reset_election_timer(state)
            state = %{state | voted_for: candidate}
            follower(state, extra_state)
        else
          #IO.puts("Follower #{whoami()} vote not granted to candidate #{candidate}.")
          send(sender,
            %Raft.RequestVoteResponse{
              term: state.current_term,
              granted: false
            })
          follower(state, extra_state)
        end  


      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle a RequestVoteResponse.
        IO.puts(
          "Follower #{whoami()} received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)} and did nothing."
        )
        state = if (term > state.current_term) do
          %{state | current_term: term, current_leader: nil, voted_for: nil}
        else state end
        follower(state, extra_state)

      # Messages from external clients. In each case we
      # tell the client that it should go talk to the
      # leader.
      :election_timeout ->
        become_candidate(state)

      {sender, :nop} ->
        # #IO.puts("Server #{whoami()} redirecting client to leader #{state.current_leader}.")
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, {:enq, item}} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, :deq} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        follower(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        follower(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {state.current_leader, state.current_term})
        follower(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :follower)
        follower(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        follower(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        follower(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end

  @doc """
  This function transitions a process that is not currently
  the leader so it is a leader.
  """
  @spec become_leader(%Raft{is_leader: false}) :: no_return()
  def become_leader(state) do
    # Send out any one time messages that need to be sent
    IO.puts("#{whoami()} is becoming leader.")
    broadcast_to_others(state,
         %Raft.AppendEntryRequest{
         term: state.current_term,
         leader_id: whoami(),
         prev_log_index: nil,
         prev_log_term: nil,
         entries: nil,
         leader_commit_index: nil
         })

    leader(make_leader(reset_heartbeat_timer(state)), %{})
  end

  @doc """
  This function implements the state machine for a process
  that is currently the leader.
  """
  @spec leader(%Raft{is_leader: true}, any()) :: no_return()
  def leader(state, extra_state) do
    receive do
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        IO.puts(
          "Leader #{whoami()} Received append entry for term #{term} with leader #{
            leader_id
          } " <>
            "(#{leader_commit_index})"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: leader_id, voted_for: nil}
          become_follower(state)
        end

        leader(state, extra_state)

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        IO.puts(
          "Leader #{whoami()} received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}
          become_follower(state)
        end

        if succ do #handle successful responses
          #update next index
          state = %{state | next_index:
          Map.put(state.next_index, sender, index + 2)}
          #update match index
          state = %{state | match_index:
          Map.put(state.match_index, sender, index + 1)}
          #increment number of responses for client request
          extra_state = Map.put(extra_state, index+1 , Map.get(extra_state, index+1)+1)
          #try to update commit index if possible (majority responded)
          #IO.puts("Trying to commit at leader with commit idx #{state.commit_index} and curr idx #{Map.get(extra_state, index+1)}.")
          #state = try_to_commit(state)
          if index+1 > state.commit_index &&
            Map.get(extra_state, index+1) >= length(state.view)/2+1
            && get_log_entry(state, index+1).term == state.current_term
            do
              case commit_log_index(state, index + 1) do
                {{a,b}, returnState} ->
                  send(a, b)
                  leader(returnState, extra_state)
                {_, returnState} ->
                  leader(returnState, extra_state)

            end
          end
          leader(state, extra_state)
        else #handle failed responses
          #decrement next index of the sender
          state = %{state | next_index:
          Map.put(state.next_index, sender, state.next_index[sender]-1)}
          #retry append entry
          send(sender,
            %Raft.AppendEntryRequest{ 
            term: state.current_term,
            leader_id: state.current_leader,
            prev_log_index: get_last_log_index(state)-1,
            prev_log_term: get_last_log_term(state), #TODO : change this
            entries: get_log_suffix(state, state.next_index[sender]), #send log starting at next index
            leader_commit_index: state.commit_index
          })
          leader(state, extra_state)
        end

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote call at the leader.
        IO.puts(
          "Leader #{whoami()} received RequestVote " <>
            "term = #{term}, candidate = #{candidate}"
        )
        if (term > state.current_term) do
          #IO.puts("Leader #{whoami()} converting to follower.")
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}
          become_follower(state)
        end
        leader(state, extra_state)

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle RequestVoteResponse at a leader.         
        IO.puts(
          "Leader #{whoami()} received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}
          become_follower(state)
        end
        leader(state, extra_state)

      :heartbeat_timeout ->
        broadcast_to_others(state,
         %Raft.AppendEntryRequest{
         term: state.current_term,
         leader_id: whoami(),
         prev_log_index: nil,
         prev_log_term: nil,
         entries: nil,
         leader_commit_index: nil
         })
         
        leader(reset_heartbeat_timer(state), extra_state)

      # Messages from external clients. 
      {sender, :nop} ->
        entry =
          Raft.LogEntry.nop(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )

        # append entry to local log, respond after entry applied to state 
        broadcast_to_others(state, %Raft.AppendEntryRequest{ #broadcasting once is enough since no packet loss
         term: state.current_term,
         leader_id: whoami(),
         prev_log_index: get_last_log_index(state),
         prev_log_term: get_last_log_term(state), 
         entries: [entry],
         leader_commit_index: state.commit_index
       })
        state = add_log_entries(state, [entry])

        #using extra state to record number of successful responses to client requests
        extra_state = Map.put(extra_state, get_last_log_index(state) , 1)
        leader(reset_heartbeat_timer(state), extra_state)

      {sender, {:enq, item}} ->
        entry =
          Raft.LogEntry.enqueue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender,
            item
          )
        # append entry to local log, respond after entry applied to state 
        broadcast_to_others(state, %Raft.AppendEntryRequest{ #broadcasting once is enough since no packet loss
         term: state.current_term,
         leader_id: whoami(),
         prev_log_index: get_last_log_index(state),
         prev_log_term: get_last_log_term(state), 
         entries: [entry],
         leader_commit_index: state.commit_index
       })
        state = add_log_entries(state, [entry])
        #using extra state to record client requests
        #
        extra_state = Map.put(extra_state, get_last_log_index(state) , 1)
        leader(reset_heartbeat_timer(state), extra_state)

      {sender, :deq} ->
        entry =
          Raft.LogEntry.dequeue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )
        # append entry to local log, respond after entry applied to state machine
        broadcast_to_others(state, %Raft.AppendEntryRequest{ #broadcasting once is enough since no packet loss
         term: state.current_term,
         leader_id: whoami(),
         prev_log_index: get_last_log_index(state),
         prev_log_term: get_last_log_term(state), 
         entries: [entry],
         leader_commit_index: state.commit_index
       })
        state = add_log_entries(state, [entry])
        #using extra state to record client requests
        extra_state = Map.put(extra_state, get_last_log_index(state) , 1)
        leader(reset_heartbeat_timer(state), extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        leader(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        leader(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {whoami(), state.current_term})
        leader(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :leader)
        leader(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        send(sender, :ok)

        leader(
          %{state | min_election_timeout: min, max_election_timeout: max},
          extra_state
        )

      {sender, {:set_heartbeat_timeout, timeout}} ->
        state = %{state | heartbeat_timeout: timeout}
        state = reset_heartbeat_timer(state)
        send(sender, :ok)
        leader(state, extra_state)
    end
  end

  @doc """
  This function transitions a process to candidate.
  """
  @spec become_candidate(%Raft{is_leader: false}) :: no_return()
  def become_candidate(state) do
    #On conversion to candidate, start election:
    # • Increment currentTerm
    # • Vote for self
    # • Reset election timer
    # • Send RequestVote RPCs to all other servers
    IO.puts("#{whoami()} is becoming candidate.")
    state = %{state | current_term: state.current_term+1, voted_for: whoami()}
    state = reset_election_timer(state)
    broadcast_to_others(state, %Raft.RequestVote{
                                  term: state.current_term,
                                  candidate_id: whoami(),
                                  last_log_index: get_last_log_index(state),
                                  last_log_term: get_last_log_term(state),
                                })
    candidate(state, %{voteCount: 1}) #using extra_space to track vote count
  end

  @doc """
  This function implements the state machine for a process
  that is currently a candidate.
  """
  @spec candidate(%Raft{is_leader: false}, any()) :: no_return()
  def candidate(state, extra_state) do
    # state = commit_entries(state) #TODO
    receive do
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest as a candidate
        IO.puts(
          "Candidate #{whoami()} received append entry for term #{term} " <>
            "with leader #{leader_id} " <>
            "(#{leader_commit_index} #{inspect(entries)})"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: leader_id, voted_for: nil}
          become_follower(state)
        end
        if (term == state.current_term) do
          state = %{state | current_leader: leader_id}
          become_follower(state)
        end
        candidate(state, extra_state)

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # Handle an append entry response as a candidate
        IO.puts(
          "Candidate #{whoami()} received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}     
          become_follower(state)
        end
        candidate(state, extra_state)

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # Handle a RequestVote response as a candidate.
        IO.puts(
          "Candidate #{whoami()} received RequestVote " <>
            "term = #{term}, candidate = #{candidate}"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}
          become_follower(state)
        end
        candidate(state, extra_state)

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # Handle a RequestVoteResposne as a candidate.
        IO.puts(
          "Candidate #{whoami()} received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        if (term > state.current_term) do
          state = %{state | current_term: term, current_leader: nil, voted_for: nil}
          become_follower(state)
        end
        if granted do
          extra_state = %{extra_state | voteCount: extra_state.voteCount + 1}
          if extra_state.voteCount >= Float.ceil(length(state.view)/2) do #received majority vote
            become_leader(state)
          end
          candidate(state, extra_state)
        end
        candidate(state, extra_state)

      :election_timeout ->
        become_candidate(state)
      # Messages from external clients.
      {sender, :nop} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, {:enq, item}} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, :deq} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        candidate(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        candidate(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {:candidate, state.current_term})
        candidate(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :candidate)
        candidate(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        candidate(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        candidate(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end
end

defmodule Raft.Client do
  import Emulation, only: [send: 2]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  @moduledoc """
  A client that can be used to connect and send
  requests to the RSM.
  """
  alias __MODULE__
  @enforce_keys [:leader]
  defstruct(leader: nil)

  @doc """
  Construct a new Raft Client. This takes an ID of
  any process that is in the RSM. We rely on
  redirect messages to find the correct leader.
  """
  @spec new_client(atom()) :: %Client{leader: atom()}
  def new_client(member) do
    %Client{leader: member}
  end

  @doc """
  Send a nop request to the RSM.
  """
  @spec nop(%Client{}) :: {:ok, %Client{}}
  def nop(client) do
    leader = client.leader
    #IO.puts("Client sending nop to server #{leader}.")
    send(leader, :nop)

    receive do
      {_, {:redirect, new_leader}} ->
        nop(%{client | leader: new_leader})

      {_, :ok} ->
        {:ok, client}
    end
  end

  @doc """
  Send a dequeue request to the RSM.
  """
  @spec deq(%Client{}) :: {:empty | {:value, any()}, %Client{}}
  def deq(client) do
    leader = client.leader
    send(leader, :deq)

    receive do
      {_, {:redirect, new_leader}} ->
        deq(%{client | leader: new_leader})

      {_, v} ->
        {v, client}
    end
  end

  @doc """
  Send an enqueue request to the RSM.
  """
  @spec enq(%Client{}, any()) :: {:ok, %Client{}}
  def enq(client, item) do
    leader = client.leader
    send(leader, {:enq, item})

    receive do
      {_, :ok} ->
        {:ok, client}

      {_, {:redirect, new_leader}} ->
        enq(%{client | leader: new_leader}, item)
    end
  end
end
