#!/bin/sh

OSMFILE=${1:-/home/flaktack/osm/hungary-geofabrik.osm.pbf}
#TMPOSM="$(mktemp --tmpdir hugtfs.XXXXXXX.osm)"
TMPOSM=${2:-/home/flaktack/devel/hu-gtfs/pt-data.osm}

osmosis \
               --read-pbf "$OSMFILE" outPipe.0=ways \
                   --way-key-value  inPipe.0=ways  outPipe.0=ways      keyValueList=railway.rail,railway.narrow_gauge,railway.tram,railway.light_rail,railway.subway,route.ferry \
                   --tag-filter inPipe.0=ways      outPipe.0=ways      reject-relations \
                   --used-node  inPipe.0=ways      \
               --read-pbf "$OSMFILE" outPipe.0=railways \
                   --tag-filter inPipe.0=railways  outPipe.0=railways  accept-nodes railway=halt,station \
                   --tag-filter inPipe.0=railways  outPipe.0=railways  reject-ways \
                   --tag-filter inPipe.0=railways                      reject-relations \
               --read-pbf "$OSMFILE" outPipe.0=relations \
                   --tag-filter inPipe.0=relations outPipe.0=relations accept-relations type=line,line_variant,line_segment,site,public_transport,route,route_master \
                   --tag-filter inPipe.0=relations outPipe.0=relations reject-relations route=road,bicycle,hiking,mtb \
                   --used-way   inPipe.0=relations outPipe.0=relations \
                   --used-node  inPipe.0=relations \
               --read-pbf "$OSMFILE" outPipe.0=platforms \
                   --tag-filter inPipe.0=platforms outPipe.0=platforms  accept-relations highway=platform \
                   --used-way   inPipe.0=platforms outPipe.0=platforms \
                   --used-node  inPipe.0=platforms \
               --read-pbf "$OSMFILE" outPipe.0=bus_stops \
                   --tag-filter inPipe.0=bus_stops outPipe.0=bus_stops  accept-nodes highway=bus_stop \
                   --tag-filter inPipe.0=bus_stops outPipe.0=bus_stops  reject-ways \
                   --tag-filter inPipe.0=bus_stops                      reject-relations \
               --merge --merge --merge --merge \
               --write-xml "$TMPOSM"
chmod a+r "$TMPOSM"
