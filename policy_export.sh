#!/usr/bin/env bash
#
# This script exports the given access and nat policy for the CMA given and
# puts it into the proper format for importing into Expedition
#
# based on https://live.paloaltonetworks.com/t5/expedition-articles/migrating-checkpoint-r80-updated-on-december-2020/tac-p/262571/highlight/true#M150
#
progname=${0##*/}

log() {
  echo "$progname: ""$@"
}

err() {
  log "$@" >&2
}

. /etc/profile.d/CP.sh

cd /var/log/tmp
ID="id-$$.txt"

usage () {
  echo "Usage: $progname <CMA IP> <Policy package name>"
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

CMAIP=$1
mgmt_cli login -r true -d $CMAIP > $ID

if [[ -n $2 ]]; then
  PACKAGE="$2"
else
  usage >&2
  exit 2
fi

POLICIES=$(mgmt_cli show access-layers -d $CMAIP -s $ID --format json | jq -r '."access-layers"[] | select (.domain."domain-type" == "domain") | .uid')

if ! mdsenv $CMAIP >/dev/null; then
  if [[ $CMAIP != "Global" ]]; then
    err "$CMAIP is not a proper CMA IP"
    exit 5
  fi
fi

for POLICY in $POLICIES; do
  TOP_LIMIT=$(mgmt_cli show access-rulebase -d $CMAIP offset 50000 limit 50 \
    uid $POLICY details-level "standard" use-object-dictionary true \
    --format json -s $ID | grep total | awk -F " " '{print $3}')
  OFFSET=0
  FILENAME="0_50"
  POLICY_NAME=$(mgmt_cli show access-layer -d $CMAIP -s $ID uid $POLICY \
    --format json | jq -r .name)

  log "Total Number of Rules ($POLICY_NAME): $TOP_LIMIT"
  log "Exporting Rules ($POLICY_NAME)."

  while [[ $OFFSET -lt $TOP_LIMIT ]]; do
    mgmt_cli show access-rulebase -d $CMAIP offset $OFFSET limit 50 \
      uid "$POLICY" details-level "full" use-object-dictionary true \
      --format json --conn-timeout 3600 -s $ID >>RuleSet_$FILENAME.json
    OFFSET=$((OFFSET+50));
    FILENAME="$((OFFSET+1))_$((OFFSET+50))"
    echo -n ".$OFFSET"
  done

  log "Packing up files ($POLICY_NAME)"
  ls -rt RuleSet*.json >order
  $MDS_FWDIR/Python/bin/python -m zipfile \
    -c "${POLICY_NAME}"-Rules.zip order RuleSet*.json #>/dev/null 2>&1
  log "Output ${POLICY_NAME}-Rules.zip."
  rm RuleSet*.json
done

if [[ $CMAIP != "Global" ]]; then
  TOP_LIMIT=$(mgmt_cli show nat-rulebase -d $CMAIP offset 50000 limit 50 \
    package "$PACKAGE" details-level "standard" use-object-dictionary true \
    --format json -s $ID | grep total | awk -F " " '{print $3}')
  OFFSET=0
  FILENAME="0_500"

  log "Total Number of NAT Rules: $TOP_LIMIT"
  log "Exporting NAT Rules."

  while [[ $OFFSET -lt $TOP_LIMIT ]]; do
    mgmt_cli show nat-rulebase -d $CMAIP offset $OFFSET limit 500 \
      package "$PACKAGE" details-level "full" use-object-dictionary true \
      --format json --conn-timeout 3600 -s $ID >>NATRuleSet_$FILENAME.json
    OFFSET=$((OFFSET+500));
    FILENAME="$((OFFSET+1))_$((OFFSET+500))"
    echo -n ".$OFFSET"
  done

  log "Packing up files"
  ls -rt NATRuleSet*.json >order
  $MDS_FWDIR/Python/bin/python -m zipfile \
    -c "$PACKAGE"-NatRules.zip order NATRuleSet*.json >/dev/null 2>&1
  rm NATRuleSet*.json order

  log "Output $PACKAGE-NatRules.zip."
else
  echo "Output found in $PACKAGE-Rules.zip"
fi

mgmt_cli logout -s $ID
rm $ID >/dev/null 2>&1
log "All Done.  Don't forget to grab a copy of the routing table from the gateway"

exit 0
