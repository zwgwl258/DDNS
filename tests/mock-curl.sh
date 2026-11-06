#!/bin/sh
set -eu
action=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -H) case "$2" in 'X-TC-Action: '*) action=${2#X-TC-Action: };; esac; shift 2;;
        --data-binary) body=${2#@}; shift 2;;
        *) shift;;
    esac
done
echo "$action" >> "$TEST_LOG"
jq -e '.Domain=="example.com"' "$body" >/dev/null
if [ "$action" != DescribeRecordList ]; then
    jq -e '.Value=="1.2.3.4" and .TTL==60 and .SubDomain=="home" and .RecordLineId=="0"' "$body" >/dev/null
    if [ "$action" = ModifyRecord ]; then jq -e '.RecordId==123' "$body" >/dev/null; fi
    echo '{"Response":{"RecordId":123}}'
    exit
fi
case "$TEST_CASE" in
    create) echo '{"Response":{"Error":{"Code":"ResourceNotFound.NoDataOfRecord","Message":"empty"}}}';;
    denied) echo '{"Response":{"Error":{"Code":"AuthFailure","Message":"denied"}}}';;
    *)
        value=8.8.8.8
        [ "$TEST_CASE" != unchanged ] || value=1.2.3.4
        record=$(jq -cn --arg ip "$value" '{Name:"home",Type:"A",LineId:"0",RecordId:123,Value:$ip,TTL:60}')
        if [ "$TEST_CASE" = duplicate ]; then
            printf '{"Response":{"RecordList":[%s,%s]}}\n' "$record" "$record"
        else printf '{"Response":{"RecordList":[%s]}}\n' "$record"; fi;;
esac
