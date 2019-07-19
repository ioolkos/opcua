-module(opcua_codec_binary).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include("opcua_codec.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% API Functions
-export([decode/2]).
-export([encode/2]).

%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec decode(opcua_spec(), binary()) -> {term(), binary()}.
decode(NodeId = #node_id{}, Data) when ?IS_BUILTIN_TYPE(NodeId#node_id.value) ->
    decode_builtin(NodeId, Data);
decode(NodeIds, Data) when is_list(NodeIds) ->
    decode_list(NodeIds, Data);
decode(NodeId = #node_id{}, Data) ->
    decode_schema(opcua_schema:resolve(NodeId), Data).

-spec encode(opcua_spec(), term()) -> {iolist(), term()}.
encode(NodeId = #node_id{}, Data) when ?IS_BUILTIN_TYPE(NodeId#node_id.value) ->
    encode_builtin(NodeId, Data);
encode(NodeIds, Data) when is_list(NodeIds) ->
    encode_list(NodeIds, Data);
encode(NodeId = #node_id{}, Data) ->
    encode_schema(opcua_schema:resolve(NodeId), Data).


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% decoding

decode_builtin(#node_id{type = numeric, value = Value}, Data) ->
    decode_builtin(opcua_codec:builtin_type_name(Value), Data);
decode_builtin(#node_id{value = node_id}, Data) ->
    {NodeIdMap, Data1} = decode_builtin(node_id, Data),
    {node_id_map_to_record(NodeIdMap), Data1};
decode_builtin(#node_id{value = extension_object}, Data) ->
    {ExtensionObjectMap, Data1} = decode_builtin(extension_object, Data),
    NodeId = node_id_map_to_record(maps:get(type_id, ExtensionObjectMap)),
    Body = maps:get(type_id, ExtensionObjectMap),
    {DecodedBody, _} = decode(NodeId, Body),
    {ExtensionObjectMap#{type_id => NodeId, body => DecodedBody}, Data1};
decode_builtin(#node_id{value = Value}, Data) ->
    decode_builtin(Value, Data);
decode_builtin(Type, Data) ->
    opcua_codec_binary_builtin:decode(Type, Data).

decode_schema(#structure{with_options = false, fields = Fields}, Data) ->
    decode_fields(Fields, Data);
decode_schema(#structure{with_options = true, fields = Fields}, Data) ->
    {Mask, Data1} = decode_builtin(uint32, Data),
    decode_masked_fields(Mask, Fields, Data1);
decode_schema(#union{fields = Fields}, Data) ->
    {SwitchValue, Data1} = decode_builtin(uint32, Data),
    resolve_union_value(SwitchValue, Fields, Data1);
decode_schema(#enum{fields = Fields}, Data) ->
    {Value, Data1} = decode_builtin(int32, Data),
    {resolve_enum_value(Value, Fields), Data1}.

decode_fields(Fields, Data) ->
    decode_fields(Fields, Data, #{}).

decode_fields([], Data, Acc) ->
    {Acc, Data};
decode_fields([Field | Fields], Data, Acc) ->
    {Value, Data1} = decode_field(Field, Data),
    Acc1 = maps:put(Field#field.name, Value, Acc),
    decode_fields(Fields, Data1, Acc1).

decode_field(#field{node_id = NodeId, value_rank = -1}, Data) ->
    decode(NodeId, Data);
decode_field(#field{node_id = NodeId, value_rank = N}, Data) when N >= 1 ->
    {Dims, Data1} = lists:mapfoldl(fun(_, D) ->
                                    decode_builtin(int32, D)
                                   end, Data, lists:seq(1, N)),
    decode_array(NodeId, Dims, Data1, []).

%% TODO: check the order, specs are somewhat unclear
decode_array(NodeId, [Dim], Data, _Acc) ->
    decode_list([NodeId || _ <- lists:seq(1, Dim)], Data);
decode_array(NodeId, [1|Dims], Data, Acc) ->
    {Row, Data1} = decode_array(NodeId, Dims, Data, []),
    {[Row|Acc], Data1};
decode_array(NodeId, [Dim|Dims], Data, Acc) ->
    {Row, Data1} = decode_array(NodeId, Dims, Data, []),
    decode_array(NodeId, [Dim-1|Dims], Data1, [Row|Acc]).

decode_masked_fields(Mask, Fields, Data) ->
    BooleanMask = [X==1 || <<X:1>> <= <<Mask:32/unsigned-integer>>],
    {BooleanMask1, _} = lists:split(length(Fields), lists:reverse(BooleanMask)),
    BooleanMask2 = lists:filtermap(fun({_Idx, Boolean}) -> Boolean end,
                                   lists:zip(
                                     lists:seq(1, length(BooleanMask1)), BooleanMask1)),
    {IntMask, _} = lists:unzip(BooleanMask2),
    MaskedFields = [Field || Field = #field{value=Value, is_optional=Optional} <- Fields,
                             not Optional or lists:member(Value, IntMask)],
    decode_fields(MaskedFields, Data).

resolve_union_value(SwitchValue, Fields, Data) ->
    [Field] = [F || F = #field{value=Value, is_optional=Optional} <- Fields,
                    Optional and Value == SwitchValue],
    decode_field(Field, Data).

resolve_enum_value(EnumValue, Fields) ->
    [Field] = [F || F = #field{value=Value} <- Fields, Value == EnumValue],
    #{value => Field#field.name}.

decode_list(Types, Data) ->
    decode_list(Types, Data, []).

decode_list([], Data, Acc) ->
    {lists:reverse(Acc), Data};
decode_list([Type | Types], Data, Acc) ->
    {Value, Data1}  = decode(Type, Data),
    decode_list(Types, Data1, [Value | Acc]).

%%% encoding

encode_builtin(#node_id{type = numeric, value = Value}, Data) ->
    encode_builtin(opcua_codec:builtin_type_name(Value), Data);
encode_builtin(#node_id{value = Value}, Data) ->
    encode_builtin(Value, Data);
encode_builtin(Type, Data) ->
    opcua_codec_binary_builtin:encode(Type, Data).

encode_schema(_Type, _Data) -> ok.

encode_list(Types, Data) ->
    encode_list(Types, Data, []).

encode_list([], Data, Acc) ->
    {lists:reverse(Acc), Data};
encode_list([Type | Types], [Value | Data], Acc) ->
    Result = encode(Type, Value),
    encode_list(Types, Data, [Result | Acc]).

node_id_map_to_record(#{namespace := Ns, identifier_type := Type, value := Value}) ->
    #node_id{ns = Ns, type = Type, value = Value}.

%node_id_record_to_map(#node_id{ns = Ns, type = Type, value = Value}) ->
%    #{namespace => Ns, identifier_type => Type, value => Value}.
