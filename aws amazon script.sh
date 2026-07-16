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
    for cmd in jq aws openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}[*] Instalando '$cmd'...${NC}"
            if [ -n "$(command -v apt)" ]; then sudo apt-get update -qq && sudo apt-get install -y $cmd -qq;
            elif [ -n "$(command -v yum)" ]; then sudo yum install -y $cmd -q;
            fi
        fi
    done
}

# --- Verificar configuración de AWS ---
check_aws() {
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}[X] Error: AWS CLI no está configurado o las credenciales son inválidas.${NC}"
        echo -e "${YELLOW}Por favor, ejecuta 'aws configure' primero.${NC}"
        read -p "Presione ENTER para volver..."
        return 1
    fi
    return 0
}

# --- 1. Función: AWS CloudFront (Crear) ---
crear_cloudfront() {
    check_aws || return
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}      CREAR DISTRIBUCIÓN EN AWS CLOUDFRONT          ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    read -p "Ingrese el dominio personalizado/Alias (ej. cdn.tudominio.com): " CUSTOM_DOMAIN
    read -p "Ingrese el dominio o IP de origen (ej. vps.dominio.com): " ORIGIN_DOMAIN

    if [ -z "$CUSTOM_DOMAIN" ] || [ -z "$ORIGIN_DOMAIN" ]; then
        echo -e "${RED}[X] Error: Datos incompletos.${NC}"
        return
    fi

    echo -e "\n${YELLOW}[*] Buscando certificados en us-east-1...${NC}"
    CERT_DATA=$(aws acm list-certificates --region us-east-1 --certificate-statuses ISSUED --query "CertificateSummaryList[*].[CertificateArn, DomainName]" --output text)

    if [ -z "$CERT_DATA" ]; then
        echo -e "${RED}[X] No hay certificados VALIDADOS en us-east-1.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- Certificados Disponibles ---${NC}"
    INDEX=1
    declare -A CERT_MAP
    while IFS=$'\t' read -r ARN DOMAIN; do
        echo -e " ${YELLOW}$INDEX)${NC} $DOMAIN"
        CERT_MAP[$INDEX]=$ARN
        ((INDEX++))
    done <<< "$CERT_DATA"

    read -p "Seleccione el certificado (1-$((INDEX-1))): " CERT_SELECCION
    CERT_ARN="${CERT_MAP[$CERT_SELECCION]}"

    if [ -z "$CERT_ARN" ]; then
        echo -e "${RED}[X] Selección inválida.${NC}"
        return
    fi

    # Generar CallerReference única con nanosegundos
    CALLER_REFERENCE="vpn-$(date +%s%N)"

    echo -e "${YELLOW}[*] Creando configuración JSON...${NC}"
    cat <<JSON > cf-config.json
{
    "CallerReference": "$CALLER_REFERENCE",
    "Aliases": { "Quantity": 1, "Items": ["$CUSTOM_DOMAIN"] },
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "Origin-1",
                "DomainName": "$ORIGIN_DOMAIN",
                "CustomOriginConfig": {
                    "HTTPPort": 80, "HTTPSPort": 443,
                    "OriginProtocolPolicy": "match-viewer",
                    "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] }
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "Origin-1",
        "ForwardedValues": {
            "QueryString": true,
            "Cookies": { "Forward": "all" },
            "Headers": { "Quantity": 1, "Items": ["*"] }
        },
        "TrustedSigners": { "Enabled": false, "Quantity": 0 },
        "ViewerProtocolPolicy": "allow-all",
        "MinTTL": 0, "DefaultTTL": 0, "MaxTTL": 0
    },
    "Enabled": true,
    "Comment": "VPN gRPC - $CUSTOM_DOMAIN",
    "ViewerCertificate": {
        "ACMCertificateArn": "$CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    },
    "HttpVersion": "http2"
}
JSON

    echo -e "${YELLOW}[*] Enviando a AWS (esto puede tardar)...${NC}"
    RESULT=$(aws cloudfront create-distribution --distribution-config file://cf-config.json 2>&1)
    
    if [ $? -eq 0 ]; then
        ID=$(echo "$RESULT" | jq -r '.Distribution.Id')
        DOMAIN=$(echo "$RESULT" | jq -r '.Distribution.DomainName')
        echo -e "${GREEN}[✓] Creado con éxito! ID: $ID${NC}"
        echo -e "${GREEN}[✓] Host de CloudFront: $DOMAIN${NC}"
        echo -e "${YELLOW}[!] Recuerda apuntar $CUSTOM_DOMAIN -> $DOMAIN en Cloudflare (CNAME).${NC}"
    else
        echo -e "${RED}[X] Error al crear:${NC}\n$RESULT"
    fi
    rm -f cf-config.json
}

# --- 2. Función: Solicitar Certificado AWS ACM ---
solicitar_acm() {
    check_aws || return
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}   SOLICITAR CERTIFICADO PÚBLICO EN AWS ACM         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    read -p "Ingrese el dominio (ej. cdn.tudominio.com): " ACM_DOMAIN

    echo -e "${YELLOW}[*] Solicitando certificado...${NC}"
    CERT_ARN=$(aws acm request-certificate --domain-name "$ACM_DOMAIN" --validation-method DNS --region us-east-1 --query "CertificateArn" --output text)

    echo -e "${YELLOW}[*] Esperando a que AWS genere los registros de validación...${NC}"
    
    # Bucle para esperar a que los registros DNS estén listos en la API de AWS
    for i in {1..10}; do
        VALIDATION_DATA=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region us-east-1 --query "Certificate.DomainValidationOptions[0].ResourceRecord" --output json)
        if [ "$VALIDATION_DATA" != "null" ]; then break; fi
        sleep 3
    done

    if [ "$VALIDATION_DATA" == "null" ]; then
        echo -e "${RED}[X] AWS está tardando demasiado en generar registros. Intenta listar luego.${NC}"
        return
    fi

    NAME=$(echo "$VALIDATION_DATA" | jq -r '.Name')
    VALUE=$(echo "$VALIDATION_DATA" | jq -r '.Value')

    echo -e "\n${GREEN}>>> REGISTRO CNAME PARA CLOUDFLARE <<<${NC}"
    echo -e "${CYAN}Nombre:${NC} $NAME"
    echo -e "${CYAN}Valor :${NC} $VALUE"
    echo -e "----------------------------------------------------"
    echo -e "${RED}NOTA: Desactiva el Proxy (Nube Naranja) en Cloudflare.${NC}"
    
    read -p "Presione ENTER cuando haya agregado el DNS para verificar el estado..."
    
    echo -e "${YELLOW}[*] Verificando validación (puede tardar minutos)...${NC}"
    while true; do
        STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region us-east-1 --query "Certificate.Status" --output text)
        if [ "$STATUS" == "ISSUED" ]; then
            echo -e "${GREEN}[✓] ¡Certificado EMITIDO y listo para usar!${NC}"
            break
        elif [ "$STATUS" == "FAILED" ]; then
            echo -e "${RED}[X] La validación falló.${NC}"; break
        fi
        echo -ne "${CYAN}.${NC}"
        sleep 10
    done
}

# --- 3. Función: Cloudflare Origin CA ---
crear_cloudflare() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}   CREAR CERTIFICADO ORIGIN CA (CLOUDFLARE)         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    instalar_dependencias
    read -p "Dominio (ej. vpn.tudominio.com): " CF_DOMAIN
    read -p "API Token de Cloudflare: " CF_API_KEY

    openssl genrsa -out "$CF_DOMAIN.key" 2048 2>/dev/null
    CSR=$(openssl req -new -key "$CF_DOMAIN.key" -subj "/CN=$CF_DOMAIN" | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')

    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
        -H "Authorization: Bearer $CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data '{"hostnames":["'"$CF_DOMAIN"'"],"requested_validity":5475,"request_type":"origin-rsa","csr":"'"$CSR"'"}')

    if echo "$RESPONSE" | jq -e '.success' > /dev/null; then
        echo "$RESPONSE" | jq -r '.result.certificate' > "$CF_DOMAIN.pem"
        echo -e "${GREEN}[✓] Certificado guardado como $CF_DOMAIN.pem y $CF_DOMAIN.key${NC}"
    else
        echo -e "${RED}[X] Error de Cloudflare:${NC}"
        echo "$RESPONSE" | jq -r '.errors[0].message'
    fi
}

# --- 4. Función: Listar Distribuciones ---
listar_distribuciones() {
    check_aws || return
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}       LISTA DE DISTRIBUCIONES (CLOUDFRONT)         ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    aws cloudfront list-distributions --query "DistributionList.Items[*].[Id, DomainName, Status, Enabled, Comment]" --output table
}

# --- 5. Función: Gestionar / Eliminar ---
eliminar_distribucion() {
    check_aws || return
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}         GESTIONAR / ELIMINAR DISTRIBUCIÓN          ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    
    DIST_DATA=$(aws cloudfront list-distributions --query "DistributionList.Items[*].[Id, DomainName, Status, Enabled]" --output text)
    if [ -z "$DIST_DATA" ]; then echo "No hay distribuciones."; return; fi

    echo -e "N°  | ID | Dominio | Estado | Habilitada"
    INDEX=1
    declare -A MAP_ID
    while IFS=$'\t' read -r ID DOMAIN STATUS ENABLED; do
        echo -e "${YELLOW}$INDEX)${NC} $ID | $DOMAIN | $STATUS | $ENABLED"
        MAP_ID[$INDEX]=$ID
        ((INDEX++))
    done <<< "$DIST_DATA"

    read -p "Seleccione número: " SEL
    ID_SEL="${MAP_ID[$SEL]}"
    [ -z "$ID_SEL" ] && return

    CONFIG=$(aws cloudfront get-distribution --id "$ID_SEL")
    ETAG=$(echo "$CONFIG" | jq -r '.ETag')
    ENABLED=$(echo "$CONFIG" | jq -r '.Distribution.DistributionConfig.Enabled')
    STATUS=$(echo "$CONFIG" | jq -r '.Distribution.Status')

    if [ "$ENABLED" == "true" ]; then
        read -p "La distribución está activa. ¿Desea DESHABILITARLA? (s/n): " OPT
        if [[ "$OPT" =~ ^[Ss]$ ]]; then
            NEW_CONF=$(echo "$CONFIG" | jq '.Distribution.DistributionConfig | .Enabled = false')
            echo "$NEW_CONF" > temp.json
            aws cloudfront update-distribution --id "$ID_SEL" --if-match "$ETAG" --distribution-config file://temp.json > /dev/null
            echo -e "${GREEN}[✓] Deshabilitando... Espera a que el estado sea 'Deployed' para borrar.${NC}"
            rm temp.json
        fi
    else
        if [ "$STATUS" == "Deployed" ]; then
            read -p "¿Eliminar PERMANENTEMENTE? (s/n): " OPT
            [[ "$OPT" =~ ^[Ss]$ ]] && aws cloudfront delete-distribution --id "$ID_SEL" --if-match "$ETAG" && echo -e "${GREEN}[✓] Eliminada.${NC}"
        else
            echo -e "${RED}[!] El estado es '$STATUS'. Debe ser 'Deployed' para eliminar.${NC}"
        fi
    fi
}

# --- Bucle Principal ---
instalar_dependencias
while true; do
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}       GESTOR PRO: AWS & CLOUDFLARE VPN             ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e " 1) Crear CloudFront (CDN)"
    echo -e " 2) Solicitar Certificado ACM (SSL)"
    echo -e " 3) Generar Certificado Origen (Cloudflare)"
    echo -e " 4) Listar Distribuciones"
    echo -e " 5) Deshabilitar/Eliminar Distribución"
    echo -e " 6) Salir"
    echo -e "${GREEN}====================================================${NC}"
    read -p "Opción: " OPCION

    case $OPCION in
        1) crear_cloudfront ;;
        2) solicitar_acm ;;
        3) crear_cloudflare ;;
        4) listar_distribuciones ;;
        5) eliminar_distribucion ;;
        6) exit 0 ;;
        *) echo "Opción inválida" ;;
    esac
    read -p "Presione una tecla para continuar..."
done
EOF

chmod +x menu_vpn.sh
./menu_vpn.sh
