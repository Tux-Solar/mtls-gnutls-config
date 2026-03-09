#!/bin/sh
#-----------------------------

if test $# -eq 1; then
  destination=_certs-$1
  prefix=$1
else
  destination= _cert
  prefix= "mtls"
fi

if test -z "$PASSWORD"; then
  PASSWORD=9876543210
fi
mkdir -p ${destination}

#-----------------------------

#-----------------------------
make_root_certificate() {
	local name=${1:-auth}
	certtool \
		--generate-privkey \
		--key-type=ecdsa \
        --curve=secp256r1 \
		--no-text \
		--outfile=${destination}/${prefix}-${name}.key
	certtool \
		--generate-self-signed \
		--template=templ-auth.cfg \
		--load-privkey=${destination}/${prefix}-${name}.key \
		--no-text \
		--outfile=${destination}/${prefix}-${name}.pem
}
#-----------------------------
make_server_certificate() {
	local name=${1:-server} auth=${2:-auth}
	certtool \
		--generate-privkey \
		--key-type=ecdsa \
                --curve=secp256r1 \
		--no-text \
                \
		--outfile=${destination}/${prefix}-${name}.key
	certtool \
		--generate-certificate \
		--template=templ-server.cfg \
		--load-privkey=${destination}/${prefix}-${name}.key \
		--load-ca-privkey=${destination}/${prefix}-${auth}.key \
		--load-ca-certificate=${destination}/${prefix}-${auth}.pem \
		--no-text \
		--outfile=${destination}/${prefix}-${name}.pem
	cat ${destination}/${prefix}-${name}.pem ${destination}/${prefix}-${auth}.pem > ${destination}/${prefix}-${name}.crt
}
#-----------------------------
make_client_certificate() {
	local name=${1:-client} auth=${2:-auth}
	certtool \
		--generate-privkey \
		--key-type=ecdsa \
        --curve=secp256r1 \
		--no-text \
		--outfile=${destination}/${prefix}-${name}.key
	certtool \
		--generate-certificate \
		--template=templ-client.cfg \
		--load-privkey=${destination}/${prefix}-${name}.key \
		--load-ca-privkey=${destination}/${prefix}-${auth}.key \
		--load-ca-certificate=${destination}/${prefix}-${auth}.pem \
		--no-text \
		--outfile=${destination}/${prefix}-${name}.pem
	cat ${destination}/${prefix}-${name}.pem ${destination}/${prefix}-${auth}.pem > ${destination}/${prefix}-${name}.crt

    certtool  \
          --load-ca-certificate ${destination}/${prefix}-${auth}.pem \
          --load-privkey  ${destination}/${prefix}-${name}.key \
          --load-certificate ${destination}/${prefix}-${name}.pem \
          --to-p12 --p12-name ${prefix}@mtls-client  \
          --password=$PASSWORD \
          --outder --outfile ${destination}/${prefix}-${name}.pfx

}

#-----------------------------
make_root_certificate root
make_server_certificate  server root
make_client_certificate  client root
