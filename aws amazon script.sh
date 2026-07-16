cat << 'EOF' > menu_vpn.sh
#!/bin/bash

# --- Colores para la interfaz ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

# --- Función para instalar dependencias ---
instalar_dependencias() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}[*] Instalando 'jq' (requerido para procesar JSON)...${NC}"
        if [ -n "$(command -v apt)" ]; then sudo apt-get update -qq && sudo apt-get install -y jq -qq;
        elif [ -n "$(command -v yum)" ]; then sudo yum install -y jq -q;
        fi
    fi
}

# --- 1. Función: AWS CloudFront (Crear) ---
crear_cloudfront() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}      CREAR DISTRIBUCIÓN EN AWS CLOUDFRONT          ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    read -p "Ingrese el dominio personalizado/Alias (ej. cdn.freenethn.org): " CUSTOM_DOMAIN
    read -p "Ingrese el dominio o IP de origen (ej. xxxx.vps.com o tu IP): " ORIGIN_DOMAIN

    if [ -z "$CUSTOM_DOMAIN" ] || [ -z "$ORIGIN_DOMAIN" ]; then
        echo -e "${RED}[X] Error: Ambos dominios son obligatorios. Operación cancelada.${NC}"
        return
    fi

    echo -e "\n${YELLOW}[*] Obteniendo certificados de AWS Certificate Manager (us-east-1)...${NC}"
    
    CERT_DATA=$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[*].[CertificateArn, DomainName]" --output text 2>/dev/null)

    if [ -z "$CERT_DATA" ] || [[ "$CERT_DATA" == "None" ]]; then
        echo -e "${RED}[X] No se encontraron certificados en us-east-1.${NC}"
        read -p "Ingrese el ARN del certificado manualmente: " CERT_ARN
    else
        echo -e "\n${CYAN}--- Certificados Disponibles ---${NC}"
        INDEX=1
        declare -A CERT_MAP
        
        while IFS=$'\t' read -r ARN DOMAIN; do
            if [ -n "$ARN" ]; then
                echo -e " ${YELLOW}$INDEX)${NC} Dominio: ${GREEN}$DOMAIN${NC}"
                CERT_MAP[$INDEX]=$ARN
                ((INDEX++))
            fi
        done <<< "$CERT_DATA"
        echo -e "${CYAN}----------------------------------${NC}"

        read -p "Seleccione el número del certificado a usar (1-$((INDEX-1))): " CERT_SELECCION

        if ! [[ "$CERT_SELECCION" =~ ^[0-9]+$ ]] || [ -z "${CERT_MAP[$CERT_SELECCION]}" ]; then
            echo -e "${RED}[X] Selección inválida.${NC}"
            read -p "Ingrese el ARN del certificado manualmente: " CERT_ARN
        else
            CERT_ARN="${CERT_MAP[$CERT_SELECCION]}"
        fi
    fi

    if [ -z "$CERT_ARN" ]; then
        echo -e "${RED}[X] Error: Es obligatorio asignar un certificado para la distribución.${NC}"
        return
    fi

    echo -e "\n${YELLOW}[*] Certificado seleccionado: ${GREEN}$CERT_ARN${NC}"
    echo -e "${YELLOW}[*] Generando configuración optimizada para gRPC sobre HTTP/2...${NC}"

    CALLER_REFERENCE=$(date +%s)

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

    echo -e "${YELLOW}[*] Enviando solicitud a AWS CloudFront...${NC}"
    aws cloudfront create-distribution --distribution-config file://cf-config.json

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}----------------------------------------------------${NC}"
        echo -e "${GREEN}[✓] ¡Distribución creada exitosamente para $CUSTOM_DOMAIN!${NC}"
        echo -e "${GREEN}----------------------------------------------------${NC}"
    else
        echo -e "${RED}----------------------------------------------------${NC}"
        echo -e "${RED}[X] Hubo un error al intentar crear la distribución.${NC}"
        echo -e "${RED}----------------------------------------------------${NC}"
    fi
    
    rm -f cf-config.json
}

# --- 2. Función: Solicitar Certificado AWS ACM ---
solicitar_acm() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}   SOLICITAR CERTIFICADO PÚBLICO EN AWS ACM         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}Este certificado es el que usarás en CloudFront.${NC}\n"

    read -p "Ingrese el dominio (ej. cdn.tudominio.com o *.tudominio.com): " ACM_DOMAIN

    if [ -z "$ACM_DOMAIN" ]; then
        echo -e "${RED}[X] El dominio es obligatorio.${NC}"
        return
    fi

    echo -e "\n${YELLOW}[*] Solicitando certificado a AWS ACM...${NC}"
    CERT_ARN=$(aws acm request-certificate --domain-name "$ACM_DOMAIN" --validation-method DNS --region us-east-1 --query "CertificateArn" --output text 2>/dev/null)

    if [ -z "$CERT_ARN" ]; then
        echo -e "${RED}[X] Error al solicitar. Revisa tus permisos o si el dominio es válido.${NC}"
        return
    fi

    echo -e "${GREEN}[✓] ¡Certificado solicitado! Estado: PENDIENTE DE VALIDACIÓN.${NC}"
    echo -e "${YELLOW}[*] Obteniendo los registros DNS (CNAME) necesarios...${NC}"
    
    sleep 5 # Pausa breve para que AWS genere los registros
    
    aws acm describe-certificate --certificate-arn "$CERT_ARN" --region us-east-1 \
        --query "Certificate.DomainValidationOptions[*].[DomainName, ResourceRecord.Name, ResourceRecord.Value]" \
        --output table

    echo -e "\n${RED}>>> IMPORTANTE <<<${NC}"
    echo -e "1. Ve a Cloudflare (o tu proveedor de DNS)."
    echo -e "2. Crea un registro tipo ${CYAN}CNAME${NC}."
    echo -e "3. Pega el Nombre (Name) y el Valor (Value) que aparecen en la tabla de arriba."
    echo -e "4. Guarda los cambios en Cloudflare y desactiva la nube naranja (Proxy status: DNS only)."
    echo -e "----------------------------------------------------"
    
    read -p "Presione ENTER *SOLO DESPUÉS* de haber guardado el CNAME en su DNS para verificar si se activa..."
    
    echo -e "\n${YELLOW}[*] Verificando estado en AWS (esto suele tomar de 1 a 3 minutos, espera un momento)...${NC}"
    
    # Bucle de verificación (hasta 20 intentos, cada 15 seg = 5 minutos máx)
    for i in {1..20}; do
        STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region us-east-1 --query "Certificate.Status" --output text)
        
        if [ "$STATUS" == "ISSUED" ]; then
            echo -e "\n\n${GREEN}====================================================${NC}"
            echo -e "${GREEN}[✓] ¡Excelente! El certificado ha sido validado y está ACTIVO.${NC}"
            echo -e "${GREEN}[✓] Ya puedes usar la Opción 1 para crear tu distribución.${NC}"
            echo -e "${GREEN}====================================================${NC}"
            break
        elif [ "$STATUS" == "FAILED" ]; then
            echo -e "\n\n${RED}[X] Error: La validación falló. Revisa si el CNAME es correcto.${NC}"
            break
        else
            echo -ne "${CYAN}*${NC}"
            sleep 15
        fi
    done

    if [ "$STATUS" == "PENDING_VALIDATION" ]; then
        echo -e "\n\n${YELLOW}[!] El tiempo de espera terminó, pero el certificado sigue pendiente.${NC}"
        echo -e "${YELLOW}A veces Cloudflare tarda un poco más en propagar. AWS seguirá intentando en segundo plano.${NC}"
        echo -e "Puedes intentar crear la distribución más tarde.${NC}"
    fi
}

# --- 3. Función: Cloudflare Origin CA ---
crear_cloudflare() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}   CREAR CERTIFICADO ORIGIN CA (CLOUDFLARE)         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    instalar_dependencias
    
    echo -e "${YELLOW}Nota: Este es el certificado para tu VPS/Servidor backend.${NC}\n"
    
    read -p "Ingrese el dominio para el certificado (ej. vpn.dominio.com): " CF_DOMAIN
    read -s -p "Ingrese su Cloudflare Origin CA Key: " CF_API_KEY
    echo -e "\n"

    if [ -z "$CF_DOMAIN" ] || [ -z "$CF_API_KEY" ]; then
        echo -e "${RED}[X] Error: El dominio y la API Key son obligatorios.${NC}"
        return
    fi

    echo -e "${YELLOW}[*] Generando clave y solicitando a Cloudflare...${NC}"
    openssl genrsa -out "$CF_DOMAIN.key" 2048 2>/dev/null
    openssl req -new -key "$CF_DOMAIN.key" -out "$CF_DOMAIN.csr" -subj "/C=US/ST=State/L=City/O=VPN/CN=$CF_DOMAIN" 2>/dev/null

    CSR_FORMATTED=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' "$CF_DOMAIN.csr")

    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
        -H "X-Auth-User-Service-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data '{"hostnames":["'"$CF_DOMAIN"'"],"requested_validity":5475,"request_type":"origin-rsa","csr":"'"$CSR_FORMATTED"'"}')

    CERT=$(echo "$RESPONSE" | jq -r '.result.certificate')

    if [ "$CERT" != "null" ] && [ -n "$CERT" ]; then
        echo -e "$CERT" > "$CF_DOMAIN.pem"
        echo -e "${GREEN}----------------------------------------------------${NC}"
        echo -e "${GREEN}[✓] ¡Certificado creado exitosamente (Válido por 15 años)!${NC}"
        echo -e "${GREEN}    🔑 Ruta clave privada : $(pwd)/$CF_DOMAIN.key${NC}"
        echo -e "${GREEN}    📜 Ruta certificado   : $(pwd)/$CF_DOMAIN.pem${NC}"
        echo -e "${GREEN}----------------------------------------------------${NC}"
    else
        echo -e "${RED}[X] Error al generar el certificado.${NC}"
    fi

    rm -f "$CF_DOMAIN.csr"
}

# --- 4. Función: Listar Distribuciones ---
listar_distribuciones() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}       LISTA DE DISTRIBUCIONES (CLOUDFRONT)         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${YELLOW}[*] Obteniendo datos desde AWS...${NC}\n"
    
    aws cloudfront list-distributions \
        --query "DistributionList.Items[*].[Id, DomainName, Status, Comment]" \
        --output table
}

# --- 5. Función: Eliminar Distribución con Menú de Selección ---
eliminar_distribucion() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}         GESTIONAR / ELIMINAR DISTRIBUCIÓN          ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    
    echo -e "${YELLOW}[*] Consultando distribuciones...${NC}"
    DIST_DATA=$(aws cloudfront list-distributions --query "DistributionList.Items[*].[Id, DomainName, Status]" --output text 2>/dev/null)
    
    if [ -z "$DIST_DATA" ] || [[ "$DIST_DATA" == "None" ]]; then
        echo -e "${RED}[X] No hay distribuciones disponibles en tu cuenta.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- Distribuciones Disponibles ---${NC}"
    INDEX=1
    declare -A DIST_MAP
    
    while IFS=$'\t' read -r ID DOMAIN STATUS; do
        if [ -n "$ID" ]; then
            echo -e " ${YELLOW}$INDEX)${NC} ID: ${GREEN}$ID${NC} | Dominio: $DOMAIN | Estado: $STATUS"
            DIST_MAP[$INDEX]=$ID
            ((INDEX++))
        fi
    done <<< "$DIST_DATA"
    echo -e "${CYAN}----------------------------------${NC}"

    read -p "Seleccione el número de la distribución a gestionar (1-$((INDEX-1))): " SELECCION

    if ! [[ "$SELECCION" =~ ^[0-9]+$ ]] || [ -z "${DIST_MAP[$SELECCION]}" ]; then
        echo -e "${RED}[X] Selección inválida. Operación cancelada.${NC}"
        return
    fi

    DIST_ID="${DIST_MAP[$SELECCION]}"
    echo -e "\n${YELLOW}[*] Has seleccionado la distribución: ${GREEN}$DIST_ID${NC}"
    
    ETAG=$(aws cloudfront get-distribution --id "$DIST_ID" --query "ETag" --output text 2>/dev/null)
    ENABLED=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query "DistributionConfig.Enabled" --output text)

    if [ "$ENABLED" == "True" ]; then
        echo -e "${RED}[!] La distribución actualmente está HABILITADA y no se puede eliminar.${NC}"
        read -p "¿Desea DESHABILITARLA ahora? (s/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
            aws cloudfront get-distribution-config --id "$DIST_ID" | jq '.DistributionConfig | .Enabled = false' > updated_config.json
            aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" --distribution-config file://updated_config.json > /dev/null
            echo -e "${GREEN}[✓] Distribución deshabilitada con éxito. Regresa en unos minutos para eliminarla permanentemente.${NC}"
            rm -f updated_config.json
        fi
    else
        echo -e "${GREEN}[✓] La distribución ya se encuentra DESHABILITADA.${NC}"
        read -p "¿Desea ELIMINARLA permanentemente ahora? (s/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
            aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}[✓] ¡Distribución $DIST_ID eliminada exitosamente!${NC}"
            else
                echo -e "${RED}[X] Error al eliminar. Asegúrate de que el estado sea 'Deployed' y no 'InProgress'.${NC}"
            fi
        fi
    fi
}

# --- Menú Principal en Bucle ---
while true; do
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}       GESTOR AVANZADO: AWS & CLOUDFLARE VPN        ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e " ${CYAN}1)${NC} Crear distribución en AWS CloudFront"
    echo -e " ${CYAN}2)${NC} Solicitar y Validar Certificado en AWS ACM"
    echo -e " ${CYAN}3)${NC} Generar Certificado de Origen VPS (Cloudflare)"
    echo -e " ${CYAN}4)${NC} Listar distribuciones (AWS CloudFront)"
    echo -e " ${CYAN}5)${NC} Gestionar / Eliminar distribución (AWS CloudFront)"
    echo -e " ${CYAN}6)${NC} Salir"
    echo -e "${GREEN}====================================================${NC}"
    read -p "Seleccione una opción [1-6]: " OPCION

    case $OPCION in
        1) crear_cloudfront; echo ""; read -n 1 -s -r -p "Presione cualquier tecla para continuar..." ;;
        2) solicitar_acm; echo ""; read -n 1 -s -r -p "Presione cualquier tecla para continuar..." ;;
        3) crear_cloudflare; echo ""; read -n 1 -s -r -p "Presione cualquier tecla para continuar..." ;;
        4) listar_distribuciones; echo ""; read -n 1 -s -r -p "Presione cualquier tecla para continuar..." ;;
        5) eliminar_distribucion; echo ""; read -n 1 -s -r -p "Presione cualquier tecla para continuar..." ;;
        6) echo -e "\n${YELLOW}Saliendo... ¡Hasta pronto!${NC}\n"; exit 0 ;;
        *) echo -e "\n${RED}[X] Opción no válida.${NC}"; sleep 2 ;;
    esac
done
EOF

chmod +x menu_vpn.sh
./menu_vpn.sh
