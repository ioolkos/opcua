-module(opcua_sup).

-behaviour(supervisor).

%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% API Functions
-export([start_link/0]).

%% Behaviour supervisor callback functions
-export([init/1]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%%% BEHAVIOUR supervisor CALLBACK FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
    {ok, {#{strategy => one_for_all}, [
        worker(opcua_address_space, []),
        worker(opcua_database, [#{}]),
        worker(opcua_registry, [#{}]),
        supervisor(opcua_sessions_sup, []),
        supervisor(opcua_client_sup, [])
    ]}}.


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

worker(Module, Args) ->
    #{id => Module, start => {Module, start_link, Args}}.

supervisor(Module, Args) ->
    #{id => Module, type => supervisor, start => {Module, start_link, Args}}.
