% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(couch_raft).
-behaviour(gen_statem).

-define(CLIENT_TIMEOUT, 5_000).

% maximum number of entries to send in one go.
-define(BATCH_SIZE, 10).

% public api

-export([
    start/3,
    start_link/3,
    stop/1,
    call/2
]).

% mandatory gen_statem callbacks

-export([
    init/1,
    callback_mode/0,
    handle_event/4
]).

%% public api

start(Name, StoreModule, StoreState) ->
    gen_statem:start({global, [Name, node()]}, ?MODULE, new(Name, StoreModule, StoreState), []).

start_link(Name, StoreModule, StoreState) ->
    gen_statem:start_link({global, [Name, node()]}, ?MODULE, new(Name, StoreModule, StoreState), []).

new(Name, StoreModule, StoreState) ->
    maps:merge(#{
        name => Name,
        store_module => StoreModule,
        votesGranted => undefined,
        froms => #{}
    }, StoreState).

stop(ServerRef) ->
    gen_statem:stop(ServerRef).

call(ServerRef, Value) ->
    gen_statem:call(ServerRef, #{type => 'ClientRequest', value => Value}, ?CLIENT_TIMEOUT).

init(Data) ->
    {ok, follower, Data}.

callback_mode() ->
    [handle_event_function, state_enter].

%% erlfmt-ignore
handle_event(cast, #{term := FutureTerm} = Msg, _State, #{term := CurrentTerm} = Data) when FutureTerm > CurrentTerm ->
    couch_log:notice("~p received message from future term ~B, moving to that term, becoming follower and clearing votedFor", [id(Data), FutureTerm]),
    persist({next_state, follower, Data#{term => FutureTerm, votedFor => undefined, votesGranted => undefined}, {next_event, cast, Msg}});

handle_event(enter, _OldState, follower, Data) ->
    #{term := Term, froms := Froms} = Data,
    couch_log:notice("~p became follower in term ~B", [id(Data), Term]),
    Replies = [{reply, From, {error, deposed}} || From <- maps:values(Froms)],
    persist({keep_state, maps:without([nextIndex, matchIndex], Data#{votedFor => undefined, votesGranted => undefined, froms => #{}}),
        [state_timeout(follower) | Replies]});

handle_event(enter, _OldState, candidate, Data) ->
    #{term := Term} = Data,
    couch_log:notice("~p became candidate in term ~B", [id(Data), Term]),
    persist({keep_state, start_election(Data), state_timeout(candidate)});

handle_event(enter, _OldState, leader, Data) ->
    #{store_module := StoreModule, cohort := Cohort, term := Term} = Data,
    couch_log:notice("~p became leader in term ~B", [id(Data), Term]),
    Peers = peers(Cohort),
    {LastIndex, _} = StoreModule:last(Data),
    {keep_state, Data#{
        nextIndex => maps:from_list([{Peer, LastIndex + 1} || Peer <- Peers]),
        matchIndex => maps:from_list([{Peer, 0} || Peer <- Peers])
    }, state_timeout(leader)};

handle_event(cast, #{type := 'RequestVoteRequest', term := Term} = Msg, State, #{term := CurrentTerm} = Data)
  when Term =< CurrentTerm ->
    #{
        source := MSource,
        lastLogIndex := MLastLogIndex,
        lastLogTerm := MLastLogTerm
    } = Msg,
    #{
        store_module := StoreModule,
        votedFor := VotedFor
    } = Data,
    {LastIndex, LastTerm} = StoreModule:last(Data),
    LogOk = MLastLogTerm > LastTerm orelse (MLastLogTerm == LastTerm andalso MLastLogIndex >= LastIndex),
    Grant = Term == CurrentTerm andalso LogOk andalso (VotedFor == undefined orelse VotedFor == MSource),
    couch_log:notice("~p received RequestVoteRequest from ~p in term ~B when in term ~B (Grant:~p, LogOk:~p, VotedFor:~p)", [id(Data), MSource, Term, CurrentTerm, Grant, LogOk, VotedFor]),
    Reply = #{
        type => 'RequestVoteResponse',
        term => CurrentTerm,
        voteGranted => Grant,
        source => node()
    },
    cast(MSource, Reply, Data),
    if
        Grant ->
            persist({keep_state, Data#{votedFor => MSource}, state_timeout(State)});
        true ->
            {keep_state_and_data, state_timeout(State)}
    end;

handle_event(cast, #{type := 'RequestVoteResponse', term := PastTerm}, _State, #{term := CurrentTerm} = Data) when PastTerm < CurrentTerm ->
    couch_log:notice("~p ignored RequestVoteResponse from past term ~B", [id(Data), PastTerm]),
    keep_state_and_data;

handle_event(cast, #{type := 'RequestVoteResponse', term := Term} = Msg, _State, #{term := Term} = Data) ->
    #{source := MSource, voteGranted := MVoteGranted} = Msg,
    #{cohort := Cohort, votesGranted := VotesGranted0} = Data,
    VotesGranted1 = if MVoteGranted -> lists:usort([MSource | VotesGranted0]); true -> VotesGranted0 end,
    couch_log:notice("~p received RequestVoteResponse from ~p in current term ~B (VotesGranted:~p)", [id(Data), MSource, Term, VotesGranted1]),
    if
        length(VotesGranted1) >= length(Cohort) div 2 + 1 ->
            couch_log:notice("~p has enough votes to be leader in term ~B", [id(Data), Term]),
            {next_state, leader, Data#{votesGranted => VotesGranted1}};
        true ->
            {keep_state, Data#{votesGranted => VotesGranted1}}
    end;


handle_event(cast, #{type := 'AppendEntriesRequest', term := Term} = Msg, State, #{term := CurrentTerm} = Data)
  when Term =< CurrentTerm ->
    #{
        source := MSource,
        prevLogIndex := MPrevLogIndex,
        prevLogTerm := MPrevLogTerm,
        entries := MEntries,
        commitIndex := MCommitIndex
    } = Msg,
    #{
        store_module := StoreModule
    } = Data,
    {LastIndex, _LastTerm} = StoreModule:last(Data),
    LogOk = MPrevLogIndex == 0 orelse (MPrevLogIndex > 0 andalso MPrevLogIndex =< LastIndex andalso MPrevLogTerm == nthterm(MPrevLogIndex, Data)),
    if
        Term < CurrentTerm orelse (Term == CurrentTerm andalso State == follower andalso not LogOk) ->
            Reply = #{
                type => 'AppendEntriesResponse',
                term => CurrentTerm,
                success => false,
                matchIndex => 0,
                source => node()
            },
            cast(MSource, Reply, Data),
            if
                State == leader ->
                    keep_state_and_data;
                true ->
                    {keep_state_and_data, state_timeout(State)}
            end;
        Term == CurrentTerm andalso State == candidate ->
            {next_state, follower, Data, {next_event, cast, Msg}};
        Term == CurrentTerm andalso State == follower andalso LogOk ->
            if
                MEntries == [] ->
                    Reply = #{
                        type => 'AppendEntriesResponse',
                        term => CurrentTerm,
                        success => true,
                        matchIndex => MPrevLogIndex,
                        source => node()
                    },
                    couch_log:debug("~p received heartbeat and everything matches, sending matchIndex:~p", [id(Data), MPrevLogIndex]),
                    cast(MSource, Reply, Data),
                    {keep_state, update_state_machine(Data#{commitIndex => MCommitIndex}), state_timeout(State)};
                true ->
                    Index = MPrevLogIndex + 1,
                    if
                        LastIndex >= Index ->
                            {NthLogTerm, _} = StoreModule:lookup(Index, Data),
                            {FirstEntryTerm, _} = hd(MEntries),
                            if
                                NthLogTerm == FirstEntryTerm ->
                                    Reply = #{
                                        type => 'AppendEntriesResponse',
                                        term => CurrentTerm,
                                        success => true,
                                        matchIndex => MPrevLogIndex + length(MEntries),
                                        source => node()
                                    },
                                    couch_log:notice("~p received entry:~p that's already applied, sending matchIndex:~p", [id(Data), MEntries, MPrevLogIndex + length(MEntries)]),
                                    cast(MSource, Reply, Data),
                                    {keep_state, update_state_machine(Data#{commitIndex => MCommitIndex}), state_timeout(State)};
                                NthLogTerm /= FirstEntryTerm ->
                                    couch_log:notice("~p received conflicting entry:~p, deleting it", [id(Data), MEntries]),
                                    case StoreModule:truncate(LastIndex - 1, Data) of
                                        {ok, NewData} ->
                                            {keep_state, NewData, [{next_event, cast, Msg}, state_timeout(State)]};
                                        {error, Reason} ->
                                            {stop, Reason}
                                    end
                            end;
                        LastIndex == MPrevLogIndex ->
                            couch_log:notice("~p received new entries:~p, appending it to log", [id(Data), MEntries]),
                            case StoreModule:append(MEntries, Data) of
                                {ok, _EntryIndex, NewData} ->
                                    {keep_state, NewData, [{next_event, cast, Msg}, state_timeout(State)]};
                                {error, Reason} ->
                                    {stop, Reason}
                            end
                    end
            end
    end;

handle_event(cast, #{type := 'AppendEntriesResponse', term := PastTerm}, _State, #{term := CurrentTerm} = Data) when PastTerm < CurrentTerm ->
    couch_log:notice("~p ignored AppendEntriesResponse from past term ~B", [id(Data), PastTerm]),
    keep_state_and_data;

handle_event(cast, #{type := 'AppendEntriesResponse', term := Term} = Msg, leader, #{term := Term} = Data) ->
    #{success := MSuccess, matchIndex := MMatchIndex, source := MSource} = Msg,
    #{nextIndex := NextIndex, matchIndex := MatchIndex} = Data,
    couch_log:debug("~p received AppendEntriesResponse from ~p in current term ~B (Success:~p)", [id(Data), MSource, Term, MSuccess]),
    SourceNextIndex = maps:get(MSource, NextIndex),
    if
        MSuccess ->
            {keep_state, Data#{
                nextIndex => NextIndex#{MSource => MMatchIndex + 1},
                matchIndex => MatchIndex#{MSource => MMatchIndex}
            }};
        true ->
            {keep_state, Data#{
                nextIndex => NextIndex#{MSource => max(SourceNextIndex - 1, 1)}
            }}
    end;

handle_event(cast, #{type := 'AppendEntriesResponse'}, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, #{type := 'ClientRequest'} = Msg, leader, Data) ->
    #{value := Value} = Msg,
    #{term := Term, store_module := StoreModule, froms := Froms} = Data,
    Entry = {Term, Value},
    case StoreModule:append([Entry], Data) of
        {ok, EntryIndex, NewData} ->
            {keep_state, NewData#{froms => Froms#{EntryIndex => From}}};
        {error, Reason} ->
            {stop_and_reply, Reason, {reply, From, {error, Reason}}}
    end;

handle_event({call, From}, #{type := 'ClientRequest'}, _State, _Data) ->
    {keep_state_and_data, {reply, From, {error, not_leader}}};

handle_event(state_timeout, new_election, follower = State, Data) ->
    #{term := Term} = Data,
    couch_log:notice("~p election timeout in state ~p, term ~B", [id(Data), State, Term]),
    persist({next_state, candidate, Data});

handle_event(state_timeout, new_election, candidate = State, Data) ->
    #{term := Term} = Data,
    couch_log:notice("~p election timeout in state ~p, term ~B", [id(Data), State, Term]),
    persist({next_state, candidate, start_election(Data), state_timeout(State)});

handle_event(state_timeout, heartbeat, leader, Data) ->
    #{term := Term} = Data,
    couch_log:debug("~p leader sending a heartbeat in term ~B", [id(Data), Term]),
    ok = send_append_entries(Data),
    {keep_state, advance_commit_index(Data), state_timeout(leader)};

handle_event(EventType, EventContent, State, Data) ->
    {stop, {unknown_event, EventType, EventContent, State, Data}}.

send_append_entries(#{cohort := Cohort} = Data) ->
    send_append_entries(peers(Cohort), Data).

send_append_entries([], _Data) ->
    ok;
send_append_entries([Peer | Rest], Data) ->
    #{term := Term, nextIndex := NextIndex, store_module := StoreModule, commitIndex := CommitIndex} = Data,
    PrevLogIndex = maps:get(Peer, NextIndex) - 1,
    PrevLogTerm =
        if
            PrevLogIndex > 0 -> {NthTerm, _} = StoreModule:lookup(PrevLogIndex, Data), NthTerm;
            true -> 0
        end,
    {LastIndex, _} = StoreModule:last(Data),
    LastEntry = min(LastIndex, PrevLogIndex + 2),
    Entries = StoreModule:range(PrevLogIndex + 1, ?BATCH_SIZE, Data),
    Msg = #{
        type => 'AppendEntriesRequest',
        term => Term,
        source => node(),
        prevLogIndex => PrevLogIndex,
        prevLogTerm => PrevLogTerm,
        entries => Entries,
        commitIndex => min(CommitIndex, LastEntry)
    },
    cast(Peer, Msg, Data),
    send_append_entries(Rest, Data).

advance_commit_index(Data) ->
    #{matchIndex := MatchIndex, store_module := StoreModule, cohort := Cohort, term := Term} = Data,
    {LastIndex, LastTerm} = StoreModule:last(Data),
    LastIndexes = lists:sort([LastIndex | maps:values(MatchIndex)]),
    NewCommitIndex = lists:nth(length(Cohort) div 2 + 1, LastIndexes),
    if
        LastTerm == Term ->
            update_state_machine(Data#{commitIndex => NewCommitIndex});
        true ->
            Data
    end.

update_state_machine(#{lastApplied := Same, commitIndex := Same} = Data) ->
    Data;
update_state_machine(#{lastApplied := LastApplied, commitIndex := CommitIndex} = Data0) when
    LastApplied < CommitIndex
->
    #{store_module := StoreModule, froms := Froms0} = Data0,
    From = LastApplied + 1,
    {LastIndex, _} = StoreModule:last(Data0),
    To = min(LastIndex, CommitIndex),
    Fun = fun(Index, {Froms, Data}) ->
        {_, Value} = StoreModule:lookup(Index, Data),
        {Result, NewData} = StoreModule:apply(Value, Data),
        case maps:is_key(Index, Froms) of
            true ->
                gen_statem:reply(maps:get(Index, Froms), Result),
                {maps:remove(Index, Froms), NewData};
            false ->
                {Froms, NewData}
        end
    end,
    {Froms1, Data1} = lists:foldl(Fun, {Froms0, Data0}, lists:seq(From, To)),
    Data1#{froms => Froms1, lastApplied => To}.

start_election(Data) ->
    #{term := Term, cohort := Cohort, store_module := StoreModule} = Data,
    ElectionTerm = Term + 1,
    couch_log:notice("~p starting election in term ~B", [id(Data), ElectionTerm]),
    {LastLogIndex, LastLogTerm} = StoreModule:last(Data),
    RequestVote = #{
        type => 'RequestVoteRequest',
        term => ElectionTerm,
        lastLogIndex => LastLogIndex,
        lastLogTerm => LastLogTerm,
        source => node()
    },
    lists:foreach(fun(Peer) -> cast(Peer, RequestVote, Data) end, peers(Cohort)),
    Data#{term => ElectionTerm, votedFor => node(), votesGranted => [node()]}.

cast(Node, Msg, #{name := Name}) ->
    gen_statem:cast({global, [Name, Node]}, Msg).

state_timeout(follower) ->
    {state_timeout, 150 + rand:uniform(150), new_election};

state_timeout(candidate) ->
    {state_timeout, 15 + rand:uniform(15), new_election};

state_timeout(leader) ->
    {state_timeout, 75, heartbeat}.

peers(Cohort) ->
    Cohort -- [node()].


nthterm(N, Data) ->
    #{
        store_module := StoreModule
    } = Data,
    case StoreModule:lookup(N, Data) of
        not_found ->
            not_found;
        {Term, _Value} ->
            Term
        end.

persist({next_state, _NextState, NewData, _Actions} = HandleEventResult) ->
    persist(NewData, HandleEventResult);
persist({next_state, _NextState, NewData} = HandleEventResult) ->
    persist(NewData, HandleEventResult);
persist({keep_state, NewData, _Actions} = HandleEventResult) ->
    persist(NewData, HandleEventResult).

persist(Data, HandleEventResult) ->
    #{store_module := StoreModule} = Data,
    case StoreModule:save_state(Data) of
        ok ->
            HandleEventResult;
        {error, Reason} ->
            {stop, Reason}
    end.

id(#{name := Name}) ->
    [Name, node()].
