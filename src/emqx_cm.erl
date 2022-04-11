%%-------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% Channel Manager
-module(emqx_cm).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").
-include("types.hrl").

-logger_header("[CM]").

-export([start_link/0]).

-export([ register_channel/3
        , unregister_channel/1
        ]).

-export([connection_closed/1]).

-export([ get_chan_info/1
        , get_chan_info/2
        , set_chan_info/2
        ]).

-export([ get_chan_stats/1
        , get_chan_stats/2
        , set_chan_stats/2
        ]).

-export([get_chann_conn_mod/2]).

-export([ open_session/3
        , discard_session/1
        , discard_session/2
        , takeover_session/1
        , takeover_session/2
        , kick_session/1
        , kick_session/2
        ]).

-export([ lookup_channels/1
        , lookup_channels/2
        ]).

-export([all_channels/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

%% Internal export
-export([stats_fun/0, clean_down/1]).

%% Test export
-export([register_channel_/3]).

-type(chan_pid() :: pid()).

%% Tables for channel management.
-define(CHAN_TAB, emqx_channel).
-define(CHAN_CONN_TAB, emqx_channel_conn).
-define(CHAN_INFO_TAB, emqx_channel_info).

-define(CHAN_STATS,
        [{?CHAN_TAB, 'channels.count', 'channels.max'},
         {?CHAN_TAB, 'sessions.count', 'sessions.max'},
         {?CHAN_CONN_TAB, 'connections.count', 'connections.max'}
        ]).

%% Batch drain
-define(BATCH_SIZE, 100000).

%% Server name
-define(CM, ?MODULE).

-define(T_KICK, 5000).
-define(T_GET_INFO, 5000).
-define(T_TAKEOVER, 15000).

%% @doc Start the channel manager.
-spec(start_link() -> startlink_ret()).
start_link() ->
    gen_server:start_link({local, ?CM}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Register a channel with info and stats.
-spec(register_channel(emqx_types:clientid(),
                       emqx_types:infos(),
                       emqx_types:stats()) -> ok).
register_channel(ClientId, Info = #{conninfo := ConnInfo}, Stats) ->
    Chan = {ClientId, ChanPid = self()},
    true = ets:insert(?CHAN_INFO_TAB, {Chan, Info, Stats}),
    register_channel_(ClientId, ChanPid, ConnInfo).

%% @private
%% @doc Register a channel with pid and conn_mod.
%%
%% There is a Race-Condition on one node or cluster when many connections
%% login to Broker with the same clientid. We should register it and save
%% the conn_mod first for taking up the clientid access right.
%%
%% Note that: It should be called on a lock transaction
register_channel_(ClientId, ChanPid, #{conn_mod := ConnMod}) when is_pid(ChanPid) ->
    Chan = {ClientId, ChanPid},
    true = ets:insert(?CHAN_TAB, Chan),
    true = ets:insert(?CHAN_CONN_TAB, {Chan, ConnMod}),
    ok = emqx_cm_registry:register_channel(Chan),
    cast({registered, Chan}).

%% @doc Unregister a channel.
-spec(unregister_channel(emqx_types:clientid()) -> ok).
unregister_channel(ClientId) when is_binary(ClientId) ->
    true = do_unregister_channel({ClientId, self()}),
    ok.

%% @private
do_unregister_channel(Chan) ->
    ok = emqx_cm_registry:unregister_channel(Chan),
    true = ets:delete(?CHAN_CONN_TAB, Chan),
    true = ets:delete(?CHAN_INFO_TAB, Chan),
    ets:delete_object(?CHAN_TAB, Chan).

-spec(connection_closed(emqx_types:clientid()) -> true).
connection_closed(ClientId) ->
    connection_closed(ClientId, self()).

-spec(connection_closed(emqx_types:clientid(), chan_pid()) -> true).
connection_closed(ClientId, ChanPid) ->
    ets:delete_object(?CHAN_CONN_TAB, {ClientId, ChanPid}).

%% @doc Get info of a channel.
-spec(get_chan_info(emqx_types:clientid()) -> maybe(emqx_types:infos())).
get_chan_info(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_info(ClientId, ChanPid) end).

-spec(get_chan_info(emqx_types:clientid(), chan_pid())
      -> maybe(emqx_types:infos())).
get_chan_info(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try ets:lookup_element(?CHAN_INFO_TAB, Chan, 2)
    catch
        error:badarg -> undefined
    end;
get_chan_info(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chan_info, [ClientId, ChanPid], ?T_GET_INFO).

%% @doc Update infos of the channel.
-spec(set_chan_info(emqx_types:clientid(), emqx_types:attrs()) -> boolean()).
set_chan_info(ClientId, Info) when is_binary(ClientId) ->
    Chan = {ClientId, self()},
    try ets:update_element(?CHAN_INFO_TAB, Chan, {2, Info})
    catch
        error:badarg -> false
    end.

%% @doc Get channel's stats.
-spec(get_chan_stats(emqx_types:clientid()) -> maybe(emqx_types:stats())).
get_chan_stats(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_stats(ClientId, ChanPid) end).

-spec(get_chan_stats(emqx_types:clientid(), chan_pid())
      -> maybe(emqx_types:stats())).
get_chan_stats(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try ets:lookup_element(?CHAN_INFO_TAB, Chan, 3)
    catch
        error:badarg -> undefined
    end;
get_chan_stats(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chan_stats, [ClientId, ChanPid], ?T_GET_INFO).

%% @doc Set channel's stats.
-spec(set_chan_stats(emqx_types:clientid(), emqx_types:stats()) -> boolean()).
set_chan_stats(ClientId, Stats) when is_binary(ClientId) ->
    set_chan_stats(ClientId, self(), Stats).

-spec(set_chan_stats(emqx_types:clientid(), chan_pid(), emqx_types:stats())
      -> boolean()).
set_chan_stats(ClientId, ChanPid, Stats) ->
    Chan = {ClientId, ChanPid},
    try ets:update_element(?CHAN_INFO_TAB, Chan, {3, Stats})
    catch
        error:badarg -> false
    end.

%% @doc Open a session.
-spec(open_session(boolean(), emqx_types:clientinfo(), emqx_types:conninfo())
      -> {ok, #{session  := emqx_session:session(),
                present  := boolean(),
                pendings => list()}}
       | {error, Reason :: term()}).
open_session(true, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    CleanStart = fun(_) ->
                     ok = discard_session(ClientId),
                     Session = create_session(ClientInfo, ConnInfo),
                     register_channel_(ClientId, Self, ConnInfo),
                     {ok, #{session => Session, present => false}}
                 end,
    emqx_cm_locker:trans(ClientId, CleanStart);

open_session(false, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    ResumeStart = fun(_) ->
                      case takeover_session(ClientId) of
                          {ok, ConnMod, ChanPid, Session} ->
                              ok = emqx_session:resume(ClientInfo, Session),
                              Pendings = ConnMod:call(ChanPid, {takeover, 'end'}, ?T_TAKEOVER),
                              register_channel_(ClientId, Self, ConnInfo),
                              {ok, #{session  => Session,
                                     present  => true,
                                     pendings => Pendings}};
                          {error, not_found} ->
                              Session = create_session(ClientInfo, ConnInfo),
                              register_channel_(ClientId, Self, ConnInfo),
                              {ok, #{session => Session, present => false}}
                      end
                  end,
    emqx_cm_locker:trans(ClientId, ResumeStart).

create_session(ClientInfo, ConnInfo) ->
    Session = emqx_session:init(ClientInfo, ConnInfo),
    ok = emqx_metrics:inc('session.created'),
    ok = emqx_hooks:run('session.created', [ClientInfo, emqx_session:info(Session)]),
    Session.

%% @doc Try to takeover a session.
-spec(takeover_session(emqx_types:clientid())
      -> {error, term()}
       | {ok, atom(), pid(), emqx_session:session()}).
takeover_session(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> {error, not_found};
        [ChanPid] ->
            takeover_session(ClientId, ChanPid);
        ChanPids ->
            [ChanPid|StalePids] = lists:reverse(ChanPids),
            ?LOG(error, "more_than_one_channel_found: ~p", [ChanPids]),
            lists:foreach(fun(StalePid) ->
                                  catch discard_session(ClientId, StalePid)
                          end, StalePids),
            takeover_session(ClientId, ChanPid)
    end.

takeover_session(ClientId, ChanPid) when node(ChanPid) == node() ->
    case get_chann_conn_mod(ClientId, ChanPid) of
        undefined ->
            {error, not_found};
        ConnMod when is_atom(ConnMod) ->
            %% TODO: if takeover times out, maybe kill the old?
            Session = ConnMod:call(ChanPid, {takeover, 'begin'}, ?T_TAKEOVER),
            {ok, ConnMod, ChanPid, Session}
    end;
takeover_session(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), takeover_session, [ClientId, ChanPid], ?T_TAKEOVER).

%% @doc Discard all the sessions identified by the ClientId.
-spec(discard_session(emqx_types:clientid()) -> ok).
discard_session(ClientId) when is_binary(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> ok;
        ChanPids -> lists:foreach(fun(Pid) -> discard_session(ClientId, Pid) end, ChanPids)
    end.

%% @private Kick a local stale session to force it step down.
%% If failed to kick (e.g. timeout) force a kill.
%% Keeping the stale pid around, or returning error or raise an exception
%% benefits nobody.
-spec kick_or_kill(kick | discard, module(), pid()) -> ok.
kick_or_kill(Action, ConnMod, Pid) ->
    try
        %% this is essentailly a gen_server:call implemented in emqx_connection
        %% and emqx_ws_connection.
        %% the handle_call is implemented in emqx_channel
        ok = apply(ConnMod, call, [Pid, Action, ?T_KICK])
    catch
        _ : noproc -> % emqx_ws_connection: call
            ?LOG(debug, "session_already_gone: ~p, action: ~p", [Pid, Action]),
            ok;
        _ : {noproc, _} -> % emqx_connection: gen_server:call
            ?LOG(debug, "session_already_gone: ~p, action: ~p", [Pid, Action]),
            ok;
        _ : {shutdown, _} ->
            ?LOG(debug, "session_already_shutdown: ~p, action: ~p", [Pid, Action]),
            ok;
        _ : {{shutdown, _}, _} ->
            ?LOG(debug, "session_already_shutdown: ~p, action: ~p", [Pid, Action]),
            ok;
        _ : {timeout, {gen_server, call, _}} ->
            ?LOG(warning, "session_kick_timeout: ~p, action: ~p, "
                          "stale_channel: ~0p",
                          [Pid, Action, stale_channel_info(Pid)]),
            ok = force_kill(Pid);
        _ : Error ->
            ?LOG(error, "session_kick_exception: ~p, action: ~p, "
                        "reason: ~p, stacktrace: ~0p, stale_channel: ~0p",
                        [Pid, Action, Error, erlang:get_stacktrace(), stale_channel_info(Pid)]),
            ok = force_kill(Pid)
    end.

force_kill(Pid) ->
    exit(Pid, kill),
    ok.

stale_channel_info(Pid) ->
    process_info(Pid, [status, message_queue_len, current_stacktrace]).

discard_session(ClientId, ChanPid) ->
    kick_session(discard, ClientId, ChanPid).

kick_session(ClientId, ChanPid) ->
    kick_session(kick, ClientId, ChanPid).

%% @private This function is shared for session 'kick' and 'discard' (as the first arg Action).
kick_session(Action, ClientId, ChanPid) when node(ChanPid) == node() ->
    case get_chann_conn_mod(ClientId, ChanPid) of
        undefined ->
            %% already deregistered
            ok;
        ConnMod when is_atom(ConnMod) ->
            ok = kick_or_kill(Action, ConnMod, ChanPid)
    end;
kick_session(Action, ClientId, ChanPid) ->
    %% call remote node on the old APIs because we do not know if they have upgraded
    %% to have kick_session/3
    Function = case Action of
                   discard -> discard_session;
                   kick -> kick_session
               end,
    try
        rpc_call(node(ChanPid), Function, [ClientId, ChanPid], ?T_KICK)
    catch
        Error : Reason ->
            %% This should mostly be RPC failures.
            %% However, if the node is still running the old version
            %% code (prior to emqx app 4.3.10) some of the RPC handler
            %% exceptions may get propagated to a new version node
            ?LOG(error, "failed_to_kick_session_on_remote_node ~p: ~p ~p ~p",
                 [node(ChanPid), Action, Error, Reason])
    end.

kick_session(ClientId) ->
    case lookup_channels(ClientId) of
        [] ->
            ?LOG(warning, "kiecked_an_unknown_session ~ts", [ClientId]),
            ok;
        ChanPids ->
            case length(ChanPids) > 1 of
                true -> ?LOG(info, "more_than_one_channel_found: ~p", [ChanPids]);
                false -> ok
            end,
            lists:foreach(fun(Pid) -> kick_session(ClientId, Pid) end, ChanPids)
    end.

%% @doc Is clean start?
% is_clean_start(#{clean_start := false}) -> false;
% is_clean_start(_Attrs) -> true.

with_channel(ClientId, Fun) ->
    case lookup_channels(ClientId) of
        []    -> undefined;
        [Pid] -> Fun(Pid);
        Pids  -> Fun(lists:last(Pids))
    end.

%% @doc Get all channels registed.
all_channels() ->
    Pat = [{{'_', '$1'}, [], ['$1']}],
    ets:select(?CHAN_TAB, Pat).

%% @doc Lookup channels.
-spec(lookup_channels(emqx_types:clientid()) -> list(chan_pid())).
lookup_channels(ClientId) ->
    lookup_channels(global, ClientId).

%% @doc Lookup local or global channels.
-spec(lookup_channels(local | global, emqx_types:clientid()) -> list(chan_pid())).
lookup_channels(global, ClientId) ->
    case emqx_cm_registry:is_enabled() of
        true ->
            emqx_cm_registry:lookup_channels(ClientId);
        false ->
            lookup_channels(local, ClientId)
    end;

lookup_channels(local, ClientId) ->
    [ChanPid || {_, ChanPid} <- ets:lookup(?CHAN_TAB, ClientId)].

%% @private
rpc_call(Node, Fun, Args, Timeout) ->
    case rpc:call(Node, ?MODULE, Fun, Args, 2 * Timeout) of
        {badrpc, Reason} ->
            %% since eqmx app 4.3.10, the 'kick' and 'discard' calls hanndler
            %% should catch all exceptions and always return 'ok'.
            %% This leaves 'badrpc' only possible when there is problem
            %% calling the remote node.
            error({badrpc, Reason});
        Res ->
            Res
    end.

%% @private
cast(Msg) -> gen_server:cast(?CM, Msg).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    TabOpts = [public, {write_concurrency, true}],
    ok = emqx_tables:new(?CHAN_TAB, [bag, {read_concurrency, true}|TabOpts]),
    ok = emqx_tables:new(?CHAN_CONN_TAB, [bag | TabOpts]),
    ok = emqx_tables:new(?CHAN_INFO_TAB, [set, compressed | TabOpts]),
    ok = emqx_stats:update_interval(chan_stats, fun ?MODULE:stats_fun/0),
    {ok, #{chan_pmon => emqx_pmon:new()}}.

handle_call(Req, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast({registered, {ClientId, ChanPid}}, State = #{chan_pmon := PMon}) ->
    PMon1 = emqx_pmon:monitor(ChanPid, ClientId, PMon),
    {noreply, State#{chan_pmon := PMon1}};

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State = #{chan_pmon := PMon}) ->
    ChanPids = [Pid | emqx_misc:drain_down(?BATCH_SIZE)],
    {Items, PMon1} = emqx_pmon:erase_all(ChanPids, PMon),
    ok = emqx_pool:async_submit(fun lists:foreach/2, [fun ?MODULE:clean_down/1, Items]),
    {noreply, State#{chan_pmon := PMon1}};

handle_info(Info, State) ->
    ?LOG(error, "Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    emqx_stats:cancel_update(chan_stats).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

clean_down({ChanPid, ClientId}) ->
    do_unregister_channel({ClientId, ChanPid}).

stats_fun() ->
    lists:foreach(fun update_stats/1, ?CHAN_STATS).

update_stats({Tab, Stat, MaxStat}) ->
    case ets:info(Tab, size) of
        undefined -> ok;
        Size -> emqx_stats:setstat(Stat, MaxStat, Size)
    end.

get_chann_conn_mod(ClientId, ChanPid) when node(ChanPid) == node() ->
    Chan = {ClientId, ChanPid},
    try [ConnMod] = ets:lookup_element(?CHAN_CONN_TAB, Chan, 2), ConnMod
    catch
        error:badarg -> undefined
    end;
get_chann_conn_mod(ClientId, ChanPid) ->
    rpc_call(node(ChanPid), get_chann_conn_mod, [ClientId, ChanPid], ?T_GET_INFO).

