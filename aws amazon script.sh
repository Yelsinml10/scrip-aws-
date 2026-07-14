cat << 'EOF' > crear_vpn.sh
#!/bin/bash

# Solicitar los dominios necesarios al usuario
read -p "Ingrese el dominio personalizado/Alias (ej. cdn.freenethn.org): " CUSTOM_DOMAIN
read -p "Ingrese el dominio o IP de origen (ej. xxxx.vps.com o tu IP): " ORIGIN_DOMAIN

# Validar que los campos no estén vacíos
if [ -z "$CUSTOM_DOMAIN" ] || [ -z "$ORIGIN_DOMAIN" ]; then
    echo "Error: Ambos dominios son obligatorios. Operación cancelada."
    exit 1
fi

echo "Generando configuración optimizada para gRPC sobre HTTP/2..."

CALLER_REFERENCE=$(date +%s)
CERT_ARN="arn:aws:acm:us-east-1:759544957764:certificate/88f9ffa4-a3d2-42b7-b93f-8126589fa1fc"

cat <<JSON > cf-config.json
{
    "CallerReference": "$CALLER_REFERENCE",
    "Aliases": {
        "Quantity": 1,
        "Items": [
            "$CUSTOM_DOMAIN"
        ]
    },
    "DefaultRootObject": "",
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "Origin-$ORIGIN_DOMAIN",
                "DomainName": "$ORIGIN_DOMAIN",
                "OriginPath": "",
                "CustomHeaders": {
                    "Quantity": 0
                },
                "CustomOriginConfig": {
                    "HTTPPort": 80,
                    "HTTPSPort": 443,
                    "OriginProtocolPolicy": "match-viewer",
                    "OriginSslProtocols": {
                        "Quantity": 1,
                        "Items": ["TLSv1.2"]
                    },
                    "OriginReadTimeout": 30,
                    "OriginKeepaliveTimeout": 5
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "Origin-$ORIGIN_DOMAIN",
        "ForwardedValues": {
            "QueryString": true,
            "Cookies": {
                "Forward": "all"
            },
            "Headers": {
                "Quantity": 1,
                "Items": ["*"]
            }
        },
        "TrustedSigners": {
            "Enabled": false,
            "Quantity": 0
        },
        "ViewerProtocolPolicy": "allow-all",
        "MinTTL": 0,
        "AllowedMethods": {
            "Quantity": 7,
            "Items": ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["HEAD", "GET"]
            }
        },
        "SmoothStreaming": false,
        "DefaultTTL": 0,
        "MaxTTL": 0,
        "Compress": false
    },
    "CacheBehaviors": {
        "Quantity": 0
    },
    "CustomErrorResponses": {
        "Quantity": 0
    },
    "Comment": "Distribucion optimizada para VPN/gRPC - $CUSTOM_DOMAIN",
    "Logging": {
        "Enabled": false,
        "IncludeCookies": false,
        "Bucket": "",
        "Prefix": ""
    },
    "PriceClass": "PriceClass_All",
    "Enabled": true,
    "ViewerCertificate": {
        "ACMCertificateArn": "$CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021",
        "CloudFrontDefaultCertificate": false
    },
    "Restrictions": {
        "GeoRestriction": {
            "RestrictionType": "none",
            "Quantity": 0
        }
    },
    "WebACLId": "",
    "HttpVersion": "http2",
    "IsIPV6Enabled": true
}
JSON

echo "Enviando solicitud a AWS CloudFront..."

# Ejecutar el comando para crear la distribución
aws cloudfront create-distribution --distribution-config file://cf-config.json

# Verificar si el comando se ejecutó con éxito
if [ $? -eq 0 ]; then
    echo "----------------------------------------------------"
    echo "¡Distribución creada exitosamente para $CUSTOM_DOMAIN!"
else
    echo "----------------------------------------------------"
    echo "Hubo un error al intentar crear la distribución."
fi

# Eliminar el archivo JSON temporal
rm cf-config.json
EOF

# Dar permisos y ejecutar
chmod +x crear_vpn.sh
./crear_vpn.sh
