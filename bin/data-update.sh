#!/bin/bash

ALLGTFS="/var/www/sites/data.flaktack.net/html/transit/minden/latest/feed/gtfs.zip"
OSMFILE="/var/www/sites/data.flaktack.net/html/osm/hungary-current.osm.bz2"
TMPOSM="$(mktemp --tmpdir hugtfs.XXXXXXX.osm)"

osmosis \
		--read-xml "$OSMFILE" outPipe.0=ways \
		--way-key-value  inPipe.0=ways      outPipe.0=ways      keyValueList=railway.rail,railway.narrow_gauge,route.ferry \
				--tag-filter inPipe.0=ways      outPipe.0=ways      reject-relations \
				--used-node  inPipe.0=ways      \
		--read-xml "$OSMFILE" outPipe.0=railways \
		--tag-filter     inPipe.0=railways  outPipe.0=railways  accept-nodes railway=halt,station \
				--tag-filter inPipe.0=railways  outPipe.0=railways  reject-ways \
				--tag-filter inPipe.0=railways                      reject-relations \
		--read-xml "$OSMFILE" outPipe.0=relations\
		--tag-filter     inPipe.0=relations outPipe.0=relations accept-relations type=line,line_variant,line_segment,site,public_transport,route,route_master \
		--tag-filter     inPipe.0=relations outPipe.0=relations reject-relations route=road \
				--used-way   inPipe.0=relations outPipe.0=relations \
				--used-node  inPipe.0=relations \
		--read-xml "$OSMFILE" outPipe.0=platforms \
				--tag-filter inPipe.0=platforms outPipe.0=platforms  accept-relations highway=platform \
				--used-way   inPipe.0=platforms outPipe.0=platforms \
				--used-node  inPipe.0=platforms \
		--merge --merge --merge \
		--write-xml "$TMPOSM" &> /dev/null
chmod a+r "$TMPOSM"

#sudo -u www-data ./bin/hugtfs.pl deploy --osmfile="$TMPOSM" --quiet --automatic --all mav vt-transman kisvasut_gyermekvasut kisvasut_kbk kompok bkv volanbusz

sudo -u zdeqb osm2pgsql -s -c -d mytransit -P 5434 "$OSMFILE"
sudo -u zdeqb ./bin/hugtfs.pl db_import --purge --quiet "$ALLGTFS"
sudo -u zdeqb ./util/mapnik_preprocess.pl "$TMPOSM" | time sudo -u zdeqb osm2pgsql -s -c -d mytransit -P 5434 --prefix hugtfs -
sudo -u zdeqb touch /var/lib/mod_tile/planet-import-complete

/etc/init.d/tomcat6 stop

sudo -u zdeqb java -Xmx6G -jar /home/zdeqb/graph-builder.jar util/graph_config.xml &> /dev/null

rm -rf /var/run/onebusaway/*
chown zdeqb:tomcat6 -R /var/run/onebusaway
java -Xmx3G -jar /home/zdeqb/onebusaway-transit-data-federation-0.2.0-SNAPSHOT-withAllDependencies.jar oba-bundle.xml /var/run/onebusaway/
chown tomcat6:tomcat6 -R /var/run/onebusaway

/etc/init.d/tomcat6 start

tirex-batch "map=mapquest,mapquest-routes bbox=15.85,45.64,23.31,48.76 z=0-15"

rm -f "$TMPOSM" &> /dev/null
