#!/bin/bash

(
	echo 'route_id,sequence,stop_id,stop_name';

	# The routes don't exactly represent the laying of the tracks...
	echo '-1,1,bukl,Budapest-Keleti pu.';
	echo '-1,2,bufe,Budapest-Ferencváros';
	echo '-1,3,bukf,Budapest-Kelenföld';
	echo '-2,1,,Érd felső';
	echo '-2,2,,Tárnok';
	echo '-3,1,agal,Alsógalla';
	echo '-3,2,,Felsőgálla';
	echo '-3,3,tatb,Tatabánya';
	

	for i in $(wget http://www.vasutallomasok.hu/vonalak.php -q -O - | iconv -f ISO_8859-2 -t utf8 | grep -E -o 'vonkep.php\?num=\w+' | sort -u);
	do
		echo $i >&2
		sequence=1;
		wget -q -O - http://www.vasutallomasok.hu/$i | iconv -f ISO_8859-2 -t utf8 | grep 'allomas.php?az=' |
			(
				while read a;
				do
					name=$(    echo -n $(echo $a | ack-grep -o '<b>.*' | cut -d'>' -f2 | cut -d'<' -f1))
					stop_id=$( echo -n $(echo $a | ack-grep 'allomas\.php\?az=(\w+)' --output='$1' | sort -u))
					route_id=$(echo -n $(echo $i | cut -d'=' -f 2))
					printf "\t$sequence: $name ($stop_id)\n" >&2
					printf "$route_id\t,$sequence,$stop_id,$name\n"
					sequence=$(($sequence + 1));
				done
			);
	done
) | sort -n --stable | sed 's/\t//' | unix2dos
