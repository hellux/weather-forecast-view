#!/bin/env sh

warn() {
    str=$1
    [ -n "$2" ]; shift
    printf 'warning: '"$str"'\n' "$@" 1>&2
}
die() {
    str=$1
    [ -n "$2" ]; shift
    printf 'error: '"$str"'\n' "$@" 1>&2
    rm -rf "$RNT_DIR"
    exit 1
}

if [ -z "$XDG_CACHE_HOME" ];
then CCH_DIR="$HOME/.cache/wfv"
else CCH_DIR="$XDG_CACHE_HOME/wfv"
fi
if [ -z "$XDG_RUNTIME_DIR" ];
then RNT_DIR="$CCH_DIR/runtime"
else RNT_DIR="$XDG_RUNTIME_DIR/wfv"
fi

[ -z "$WFV_DAY_FMT" ] && WFV_DAY_FMT="%A, %B %d:"
[ -z "$WFV_LON" ] && WFV_LON="16"
[ -z "$WFV_LAT" ] && WFV_LAT="58"

NRMCOL='\033[0m'
DAYCOL='\033[33;1m'
# weather conditions
CNDCOL='\033[0;1m'
PRCCOL='\033[34;1m'
CLDCOL='\033[34;1m'
MODCOL='\033[35;1m'
WRMCOL='\033[31;1m'
THUCOL='\033[31;1m'

FORECASTS="$CCH_DIR/forecasts"

# fetch and parse forecasts from smhi
sync_cmd() {
    URL="https://opendata-download-metfcst.smhi.se"
    API="/api/category/pmp3g/version/2/geotype/point"
    API_CALL="$URL$API/lon/$WFV_LON/lat/$WFV_LAT/data.json"
    JQ_PARSE='.timeSeries[] | [
        .validTime,                                               #time
        (.parameters[] | select(.name == "t") | .values[0]),      #temp
        (.parameters[] | select(.name == "ws") | .values[0]),     #windspeed
        (.parameters[] | select(.name == "Wsymb2") | .values[0]), #symbol
        (.parameters[] | select(.name == "pcat") | .values[0]),   #precip
        (.parameters[] | select(.name == "pmean") | .values[0]),  #precip
        (.parameters[] | select(.name == "tstm") | .values[0])    #thunder
    ] | @tsv'

    mkdir -p "$CCH_DIR"

    curl -s $API_CALL > "$RNT_DIR/weather"
    jq -r "$JQ_PARSE" "$RNT_DIR/weather" > "$FORECASTS"
}

list_disp_day() {
    symb=$(cut -f4 $dayfile | sort | uniq -c | sort -n | tail -n1 | rev | cut -c1)
    min=$(cut -f2 $dayfile | LANG=C sort -n | head -n1)
    max=$(cut -f2 $dayfile | LANG=C sort -n | tail -n1)
    maxwind=$(cut -f3 $dayfile | LANG=C sort -n | tail -n1)
    cond=$(sed "$symb!d" smhi/wsymb2)
    printf "$DAYCOL%s$NRMCOL $CLDCOL%s $NRMCOL- $WRMCOL%s $NRMCOL%s m/s\\n" \
        "$(date -d "$day" +"$WFV_DAY_FMT")" "$min" "$max" "$maxwind"
}

list_disp_forecast() {
    if [ "$pcat" -eq "0" ]; then
        cond="$(sed "$symb!d" smhi/wsymb2)"
        cndcol=$CNDCOL
    else
        cond="$(sed "$pcat!d" smhi/pcat) ($pmean mm/h)"
        cndcol=$PRCCOL
    fi
    if [ "$(echo "$temp <= ($min+($max-($min))/3)" | bc)" -eq "1" ]; then
        tmpcol=$CLDCOL
    elif [ "$(echo "$temp >= ($max-($max-($min))/3)" | bc)" -eq "1" ]; then
        tmpcol=$WRMCOL
    else
        tmpcol=$MODCOL
    fi
    if [ "$tstm" -gt "5" ]; then
        thunder="$tstm %"
    fi
    printf "$NRMCOL[%s] $tmpcol%*.1f°C$NRMCOL, %*.1f m/s $cndcol%s $THUCOL%s\n" \
        "$(date -d "$time" +"%H")" \
        4 "$temp" 3 "$wind" \
        "$cond" "$thunder"
}

# format and print fetched forecasts
list_cmd() {
    sync=false
    day_only=false
    days=1
    OPTIND=1
    while getopts sdn: flag; do
        case "$flag" in
            s) sync=true;;
            d) day_only=true;;
            n) days=$OPTARG;;
            [?]) die "invalid flag -- $OPTARG"
        esac
    done
    shift $((OPTIND-1))

    [ "$sync" = "true" ] && sync_cmd
    [ -r "$FORECASTS" ] || die "no cache, use sync command"
    if ! [ "$days" -gt 0 ] 2>/dev/null; then
        die "invalid day count -- $days"
    fi

    # split forecasts into days
    mkdir -p "$RNT_DIR"/days
    rm -f "$RNT_DIR"/days/*
    end=$(date -d"$(date +"%F") +$days days" +"%s")
    while read -r time forecast; do
        if [ $(date -d"$time" +"%s") -lt "$end" ]; then
            day="$(date -d"$time" +"%F")"
            printf "$time\t$forecast\n" >> "$RNT_DIR/days/$day"
        else
            break
        fi
    done < "$FORECASTS"

    for dayfile in "$RNT_DIR"/days/*; do
        day=$(basename $dayfile)
        list_disp_day
        if [ $day_only = "false" ]; then
            while read -r time temp wind symb pcat pmean tstm; do
                list_disp_forecast
            done < "$dayfile"
        fi
    done
}
 
command=$1
[ -z "$command" ] && list_cmd && exit 0
shift

mkdir -p "$RNT_DIR"

case "$command" in
    s|sync) sync_cmd "$@";;
    l|ls|list) list_cmd "$@";;
    *) die 'invalid command -- %s\n\n%s' "$command" "$USAGE";;
esac

rm -rf "$RNT_DIR"
