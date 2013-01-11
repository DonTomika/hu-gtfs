#!/bin/bash

echo 'stop_id,stop_name,stop_type,stop_other,stop_coord' | unix2dos
for i in  $(wget http://www.vasutallomasok.hu/abc.php -q -O - | iconv -f ISO_8859-2 -t utf8 | ack-grep "(abc.php\?betu=[a-z])'" --output='$1' | sort -u )
do
	echo $i >&2
	for z in $(wget http://www.vasutallomasok.hu/$i -q -O - | iconv -f ISO_8859-2 -t utf8 | ack-grep "(allomas.php\?az=.*)'" --output='$1' )
	do
		printf "\t$z" >&2
		TMP=$(tempfile)
		wget -q -O - "http://www.vasutallomasok.hu/$z" | iconv -f ISO_8859-2 -t utf8 > "$TMP"
		printf "\n" >&2

		stop_id=$(echo $z | ack-grep '=(\w+)' --output='$1')
		#stop_name=$( echo -n $(ack-grep "<tr align='center'><td><font.*><b>(.*)</b></font>" -m1 --output='$1' "$TMP" ))
		stop_name=$( echo -n $(ack-grep "<font size='5' color='0'><b>(.*)</b></font>"       -m1 --output='$1' "$TMP" ))
		stop_type=$( echo -n $(ack-grep "              <td>(.*)</td>"                       -m1 --output='$1' "$TMP" ))
		stop_other=$(echo -n $(ack-grep "          <font size='2' color='0'>\((.+?)\)"      -m1 --output='$1' "$TMP" ))
		stop_coord=$(echo -n $(ack-grep "<a href='http://maps\.google\.com/\?.*?'>N(.*?)° E(.*?)°</a>" -m1 --output='$1:$2' "$TMP" ))
		printf "$stop_id,\"$stop_name\",$stop_type,\"$stop_other\",$stop_coord\n" | perl -p -e 's/&#336;/Ő/g; s/&#337;/ő/g; s/&#369;/ű/g;' | unix2dos
		rm "$TMP"
	done
done
