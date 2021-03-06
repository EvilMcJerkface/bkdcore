% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
-module(bkdcore_app).
-behavior(application).
-export([start/2, stop/1]).
-compile(export_all).

% Environment variables:
%  - etc = path to etc folder
%  - name = name of node
%  - docompile = turn of compilation of erl and dtl files

init() ->
	application:start(bkdcore,permanent).

start(_Type, _Args) ->
	application:start(asn1),
	application:start(distreg),
	application:ensure_all_started(crypto),

	Params = [begin
			case application:get_env(bkdcore,K) of
				{ok,V} ->
					{K,V};
				_ ->
					{K,undefined}
			end
		end || K <- [statepath,webport,rpcport,name,key,pem,crt]],
	case butil:ds_val(name,Params) of
		undefined ->
			[Name|_] = string:tokens(butil:tolist(node()),"@"),
			application:set_env(bkdcore,name,butil:tobin(Name));
		Name ->
			ok
	end,
	% Name should be binary
	case application:get_env(bkdcore,name) of
		{ok,[_|_] = SN} ->
			application:set_env(bkdcore,name,butil:tobin(SN));
		_ ->
			ok
	end,
	bkdcore:rpccookie(),
	[begin
		Val = butil:tolist(Val1),
		case Key of
		% statepath when hd(Val) /= $~ andalso hd(Val) /= $/ andalso Val1 /= undefined ->
		% 	application:set_env(bkdcore,Key,butil:expand_path([$~,$/|butil:tolist(Val)]));
		_ when Val1 == undefined ->
			ok;
		_ ->
			application:set_env(bkdcore,Key,butil:expand_path(butil:tolist(Val)))
		end
	end || {Key,Val1} <- Params, lists:member(Key,[key,crt,pem,statepath])],

	% io:format("Application params ~p~n",[application:get_all_env(bkdcore)]),

	application:set_env(bkdcore,starttime,os:timestamp()),
	application:set_env(bkdcore,randnum,erlang:phash2([Name,os:timestamp()])),

	bkdcore_changecheck:startup_node(),
	{ok,SupPid} = bkdcore_sup:start_link(),

	case application:get_env(bkdcore,rpcport) of
		undefined ->
			ok;
		{ok,RpcPort} ->
			case get_network_interface() of
				[] -> ok;
				IP ->
					case gen_tcp:connect(IP, RpcPort,[], 100) of
						{error,_} ->
							ok;
						{ok,_S} ->
							error_logger:format("Local RPC address already taken ~p:~p~n",[butil:to_ip(IP),RpcPort]),
							init:stop()
					end,
					application:start(ranch),
					case is_tuple(IP) of
						true ->
							Limit = [{ip,IP}];
						false ->
							Limit = []
					end,
					{ok, _} = ranch:start_listener(bkdcore_in, 10,ranch_tcp,
						[{port, RpcPort}, {max_connections, infinity}|Limit],bkdcore_rpc, [])
				end
	end,
	{ok,SupPid}.


stop(_State) ->
	ok.

get_network_interface()->
	case application:get_env(bkdcore,rpc_interface_address) of
		{ok, Value} ->
			case inet:parse_address(Value) of
				{ok, IPAddress} ->
					ok;
				_ ->
					{ok, {hostent, _, [], inet, _, [IPAddress]}} = inet:gethostbyname(Value)
			end;
		_ ->
			case string:tokens(atom_to_list(node()), "@") of
				["nonode","nohost"] ->
					IPAddress = {127,0,0,1};
				[_Name, Value] ->
					case inet:parse_address(Value) of
						{ok, IPAddress} ->
							ok;
						_ ->
							{ok, Hostname} = inet:gethostname(),
							{ok, {hostent, _, [], inet, _, [IPAddress]}} = inet:gethostbyname(Hostname)
					end
			end
	end,
	case IPAddress of
		{0,0,0,0} ->
			IPAddress;
		_ ->
			{ok, Addresses} = inet:getif(),
			case lists:keyfind(IPAddress, 1, Addresses) of
				false ->
					[];
				_ ->
					IPAddress
			end
	end.
