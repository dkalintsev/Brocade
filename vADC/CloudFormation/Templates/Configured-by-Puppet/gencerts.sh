#!/bin/bash
#
# https://www.digitalocean.com/community/tutorials/openssl-essentials-working-with-ssl-certificates-private-keys-and-csrs
#

openssl req -newkey rsa:2048 -nodes \
	-keyout domain.key -out domain.csr \
	-subj "/C=US/ST=New York/L=Brooklyn/O=Example Brooklyn Company/CN=*.corp.local"

openssl x509 -signkey domain.key \
	-in domain.csr -req \
	-days 365 -out domain.crt

for j in domain.crt domain.csr domain.key; do
	awk 1 ORS=',' < $j > e-$j
done
