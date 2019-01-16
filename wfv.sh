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

USAGE="usage: wfv list [-sd] [-n days]
       wfv sync

flags:
    s       -- sync, fetch and store forecasts in cache
    d       -- display only daily forecasts
    n days  -- number of days to display"

if [ -z "$XDG_CACHE_HOME" ];
then CCH_DIR="$HOME/.cache/wfv"
else CCH_DIR="$XDG_CACHE_HOME/wfv"
fi
if [ -z "$XDG_RUNTIME_DIR" ];
then RNT_DIR="$CCH_DIR/runtime"
else RNT_DIR="$XDG_RUNTIME_DIR/wfv"
fi

[ -z "$WFV_LON" ] && WFV_LON="16"
[ -z "$WFV_LAT" ] && WFV_LAT="58"

SCRIPTDIR=$(dirname $(readlink -f "$0"))
case $LANG in
    ru*) LC=ru;;
    *) LC=en;;
esac
SMHI="$SCRIPTDIR/smhi/$LC" # TODO install to usr or include in script

NRMCOL='\033[0m'
DAYCOL='\033[0;1m'
# weather conditions
CLDCOL='\033[34;1m'
MODCOL='\033[35;1m'
WRMCOL='\033[31;1m'
WS1COL='\033[35m'
WS2COL='\033[34m'
WS3COL='\033[36m'
WS4COL='\033[32m'
WS5COL='\033[33m'
WS6COL='\033[31m'
CNDCOL='\033[0m'
PRCCOL='\033[34m'
THUCOL='\033[31;1m'

FORECASTS="$CCH_DIR/forecasts"

# fetch and parse forecasts from smhi
sync_cmd() {
    # API docs: https://opendata.smhi.se/apidocs/metfcst/index.html
    URL="https://opendata-download-metfcst.smhi.se"
    REQUEST="/api/category/pmp3g/version/2/geotype/point"
    API_CALL="$URL$REQUEST/lon/$WFV_LON/lat/$WFV_LAT/data.json"
    JQ_PARSE='.timeSeries[] | [
        .validTime,                                                 #1
        (.parameters[] | select(.name == "msl")      | .values[0]), #2
        (.parameters[] | select(.name == "t")        | .values[0]), #3
        (.parameters[] | select(.name == "vis")      | .values[0]), #4
        (.parameters[] | select(.name == "wd")       | .values[0]), #5
        (.parameters[] | select(.name == "ws")       | .values[0]), #6
        (.parameters[] | select(.name == "r")        | .values[0]), #7
        (.parameters[] | select(.name == "tstm")     | .values[0]), #8
        (.parameters[] | select(.name == "tcc_mean") | .values[0]), #9
        (.parameters[] | select(.name == "lcc_mean") | .values[0]), #10
        (.parameters[] | select(.name == "mcc_mean") | .values[0]), #11
        (.parameters[] | select(.name == "hcc_mean") | .values[0]), #12
        (.parameters[] | select(.name == "gust")     | .values[0]), #13
        (.parameters[] | select(.name == "pmin")     | .values[0]), #14
        (.parameters[] | select(.name == "pmax")     | .values[0]), #15
        (.parameters[] | select(.name == "spp")      | .values[0]), #16
        (.parameters[] | select(.name == "pcat")     | .values[0]), #17
        (.parameters[] | select(.name == "pmean")    | .values[0]), #18
        (.parameters[] | select(.name == "pmedian")  | .values[0]), #19
        (.parameters[] | select(.name == "Wsymb2")   | .values[0])  #20
    ] | @tsv' # turn json to tab separated values with 1h forecast per line

    code="$(curl --compressed -w '%{http_code}' \
                 -o "$RNT_DIR/response" -s $API_CALL)"
    if [ "$code" -ne "200" ]; then
        die "fetch failed -- $code: \"$(cat "$RNT_DIR/response")\""
    fi

    mkdir -p "$CCH_DIR"
    jq -r "$JQ_PARSE" "$RNT_DIR/response" > "$FORECASTS" || die "parse failed"
}

tfmt() {
    tcol="$MODCOL"
    if [ $(echo "$tmin != $tmax" | bc) -eq 1 ]; then
        ratio=$(echo "(100*($1-($tmin)))/($tmax-($tmin))" | bc)
        if   [ "$ratio" -lt 33 ]; then tcol=$CLDCOL
        elif [ "$ratio" -gt 67 ]; then tcol=$WRMCOL
        fi
    fi
    printf "$tcol%*.1f°C$NRMCOL" 5 "$1"
}

wsfmt() {
    wsint="$(echo "($1+0.5)/1" | bc)"
    if   [ "$wsint" -lt  3 ]; then wscol="$WS1COL"
    elif [ "$wsint" -lt  5 ]; then wscol="$WS2COL"
    elif [ "$wsint" -lt  7 ]; then wscol="$WS3COL"
    elif [ "$wsint" -lt 10 ]; then wscol="$WS4COL"
    elif [ "$wsint" -lt 20 ]; then wscol="$WS5COL"
    else                           wscol="$WS6COL"
    fi
    printf "$wscol%*.1f m/s$NRMCOL" 4 "$1"
}

list_disp_day() {
    day="$DAYCOL$(date -d "$day" +"%a %e %b")"

    tmin=$(cut -f3 "$dayfile" | LANG=C sort -n | head -n1)
    tmax=$(cut -f3 "$dayfile" | LANG=C sort -n | tail -n1)

    tccavg=$(cut -f9 "$dayfile" | LANG=C awk '{n+=1; cc+=$0} END {print cc/n}')
    tccstr=$(printf "%.0f" "$tccavg")

    wsmax="$(cut -f6 "$dayfile" | LANG=C sort -n | tail -n1)"
    wsmaxstr="$(wsfmt $wsmax)"

    gustmax="$(cut -f13 "$dayfile" | LANG=C sort -n | tail -n1)"
    gustmaxstr="$(wsfmt $gustmax)"

    ptotal="$(cut -f18 "$dayfile" | LANG=C awk '{p+=$0} END {print p}')"
    if [ "$(echo "$ptotal > 0" | bc)" -eq 1 ]; then
        ptotalstr=$(printf "$PRCCOL%.1f mm$NRMCOL" "$ptotal")
    fi

    daystr=$(echo "$day $(tfmt $tmin) $(tfmt $tmax)  $tccstr" \
                  "$(wsfmt $wsmax) ($(wsfmt $gustmax))" \
                  "$ptotalstr")
    printf "$daystr\n"
}

list_disp_forecast() {
    hour="[$(date -d "$time" +"%H")]"

    symbstr="$CNDCOL$(sed "$symb!d" "$SMHI/wsymb2")$NRMCOL"

    if [ ! "$pmean" = "0" ]
    then pmeanstr="$PRCCOL$pmean mm$NRMCOL"
    else pmeanstr=""
    fi

    if [ "$tstm" -gt "5" ]
    then tstmstr="$THUCOL$tstm%%$NRMCOL"
    else tstmstr=""
    fi

    hourstr=$(echo "$hour $(tfmt $t)" \
                   " $tcc_mean ($lcc_mean $mcc_mean $hcc_mean)" \
                   "$(wsfmt $ws) ($(wsfmt $gust)) $symbstr" \
                   "$pmeanstr $tstmstr")
    printf "$hourstr\n"
}

# format and print fetched forecasts
list_cmd() {
    sync=false
    day_only=false
    days=
    OPTIND=1
    while getopts sdn: flag; do
        case "$flag" in
            s) sync=true;;
            d) day_only=true;;
            n) days=$OPTARG;;
            [?]) die "invalid flag -- %s\n\n%s" "$OPTARG" "$USAGE"
        esac
    done
    shift $((OPTIND-1))

    [ "$sync" = "true" ] && sync_cmd
    [ -r "$FORECASTS" ] || die "no cache, use sync command"
    if [ -z "$days" ]; then
        if [ "$day_only" = "true" ]
        then days=7
        else days=1
        fi
    fi
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
            while read -r time msl t vis wd ws r tstm \
                          tcc_mean lcc_mean mcc_mean hcc_mean \
                          gust pmin pmax spp pcat pmean pmedian symb
            do list_disp_forecast
            done < "$dayfile"
        fi
    done
}
 
mkdir -p "$RNT_DIR"

command=$1
if [ -n "$command" ]; then
    shift
    case "$command" in
        s|sync) sync_cmd "$@";;
        l|ls|list) list_cmd "$@";;
        *) die 'invalid command -- %s\n\n%s' "$command" "$USAGE";;
    esac
else
    list_cmd
fi

rm -rf "$RNT_DIR"
