#!/bin/bash
# -------------------------------------------------------------
# GCP VM Setup Script: Automated Asterisk + Dograh Deployer
# -------------------------------------------------------------
echo "Starting automated Asterisk gateway deployment..."

# 1. Update OS and install Docker & Docker-Compose
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose git

# 2. Create the workspace directories
sudo mkdir -p /opt/asterisk-gateway/config
cd /opt/asterisk-gateway

# 3. Load or create .env file for credentials securely
if [ -f .env ]; then
  echo "Loading credentials from existing .env file..."
  export $(grep -v '^#' .env | xargs)
else
  echo "No .env file found. Creating a new .env file..."
  
  # Check if running interactively
  if [ -t 0 ]; then
    read -p "Enter Vobiz Username [default: dailsmart]: " V_USER
    VOBIZ_USERNAME=${V_USER:-dailsmart}
    
    read -sp "Enter Vobiz Password: " V_PASS
    echo ""
    VOBIZ_PASSWORD=${V_PASS}
    
    read -p "Enter Vobiz Domain [default: 455bdb01.sip.vobiz.ai]: " V_DOM
    VOBIZ_DOMAIN=${V_DOM:-455bdb01.sip.vobiz.ai}
    
    read -p "Enter Caller ID Number [default: +918065481144]: " V_CID
    VOBIZ_CALLERID_NUM=${V_CID:-+918065481144}
    
    read -p "Enter Caller ID Name [default: dailsmart]: " V_NAME
    VOBIZ_CALLERID_NAME=${V_NAME:-dailsmart}
    
    read -sp "Enter Asterisk ARI Password [default: Reddy@7989]: " A_PASS
    echo ""
    ARI_PASSWORD=${A_PASS:-Reddy@7989}
  else
    # Fallback default values for non-interactive/automated runs (please update .env later)
    VOBIZ_USERNAME="dailsmart"
    VOBIZ_PASSWORD="Reddy@7989"
    VOBIZ_DOMAIN="455bdb01.sip.vobiz.ai"
    VOBIZ_CALLERID_NUM="+918065481144"
    VOBIZ_CALLERID_NAME="dailsmart"
    ARI_PASSWORD="Reddy@7989"
  fi
  
  # Write the .env file
  sudo tee .env > /dev/null << EOF
VOBIZ_USERNAME=${VOBIZ_USERNAME}
VOBIZ_PASSWORD=${VOBIZ_PASSWORD}
VOBIZ_DOMAIN=${VOBIZ_DOMAIN}
VOBIZ_CALLERID_NUM=${VOBIZ_CALLERID_NUM}
VOBIZ_CALLERID_NAME=${VOBIZ_CALLERID_NAME}
ARI_APP_NAME=dograh
ARI_PASSWORD=${ARI_PASSWORD}
EOF
  
  export VOBIZ_USERNAME VOBIZ_PASSWORD VOBIZ_DOMAIN VOBIZ_CALLERID_NUM VOBIZ_CALLERID_NAME ARI_PASSWORD
  echo ".env file created successfully and credentials loaded."
fi

# 4. Write docker-compose.yml
sudo tee /opt/asterisk-gateway/docker-compose.yml > /dev/null << 'EOF'
version: '3.8'

services:
  asterisk:
    image: andrius/asterisk:latest
    container_name: asterisk-dograh-gateway
    restart: always
    ports:
      - "5060:5060/udp"
      - "10000-10099:10000-10099/udp"
    volumes:
      - ./config/pjsip.conf:/etc/asterisk/pjsip.conf:ro
      - ./config/ari.conf:/etc/asterisk/ari.conf:ro
      - ./config/http.conf:/etc/asterisk/http.conf:ro
      - ./config/extensions.conf:/etc/asterisk/extensions.conf:ro
      - ./config/websocket_client.conf:/etc/asterisk/websocket_client.conf:ro
      - ./config/modules.conf:/etc/asterisk/modules.conf:ro

  ari-proxy:
    image: python:3.10-slim
    container_name: asterisk-ari-proxy
    restart: always
    volumes:
      - ./config/ari_proxy.py:/app/ari_proxy.py:ro
    command: python /app/ari_proxy.py
    ports:
      - "8088:8088/tcp"
    depends_on:
      - asterisk
EOF

# 5. Write Asterisk configuration files dynamically using environment variables

# --- pjsip.conf ---
sudo tee /opt/asterisk-gateway/config/pjsip.conf > /dev/null << EOF
[global]
type=global
user_agent=Dograh-Asterisk-Gateway

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0

[vobiz-reg]
type=registration
transport=transport-udp
outbound_auth=vobiz-auth
server_uri=sip:${VOBIZ_DOMAIN}
client_uri=sip:${VOBIZ_USERNAME}@${VOBIZ_DOMAIN}
retry_interval=60

[vobiz-auth]
type=auth
auth_type=userpass
username=${VOBIZ_USERNAME}
password=${VOBIZ_PASSWORD}

[vobiz-trunk]
type=endpoint
transport=transport-udp
context=from-external
disallow=all
allow=ulaw
outbound_auth=vobiz-auth
aors=vobiz-aor

[vobiz-aor]
type=aor
contact=sip:${VOBIZ_DOMAIN}
EOF

# --- ari.conf ---
sudo tee /opt/asterisk-gateway/config/ari.conf > /dev/null << EOF
[general]
enabled = yes
pretty = yes

[dograh]
type = user
read_only = no
password = ${ARI_PASSWORD}
EOF

# --- http.conf ---
sudo tee /opt/asterisk-gateway/config/http.conf > /dev/null << 'EOF'
[general]
enabled = yes
bindaddr = 0.0.0.0
bindport = 8088
EOF

# --- extensions.conf ---
sudo tee /opt/asterisk-gateway/config/extensions.conf > /dev/null << EOF
[from-external]
exten => _+X.,1,NoOp(Incoming call from Vobiz to AI Extension with plus: \${EXTEN})
 same => n,Stasis(dograh)
 same => n,Hangup()

exten => _X.,1,NoOp(Incoming call from Vobiz to AI Extension: \${EXTEN})
 same => n,Stasis(dograh)
 same => n,Hangup()

[default]
exten => _+X.,1,NoOp(Outbound call from Dograh to raw extension with plus: \${EXTEN})
 same => n,Set(TEST_CID=\${FILTER(0123456789+,\${CALLERID(num)})})
 same => n,ExecIf(\$[ \${LEN(\${TEST_CID})} < 10 ]?Set(CALLERID(num)=${VOBIZ_CALLERID_NUM}))
 same => n,Set(CALLERID(name)=${VOBIZ_CALLERID_NAME})
 same => n,Set(CLEAN_NUMBER=\${FILTER(0123456789+,\${EXTEN})})
 same => n,NoOp(Cleaned number to dial: \${CLEAN_NUMBER} using CallerID: \${CALLERID(num)})
 same => n,Dial(PJSIP/vobiz-trunk/sip:\${CLEAN_NUMBER}@${VOBIZ_DOMAIN})
 same => n,Hangup()

exten => _X.,1,NoOp(Outbound call from Dograh to raw extension: \${EXTEN})
 same => n,Set(TEST_CID=\${FILTER(0123456789+,\${CALLERID(num)})})
 same => n,ExecIf(\$[ \${LEN(\${TEST_CID})} < 10 ]?Set(CALLERID(num)=${VOBIZ_CALLERID_NUM}))
 same => n,Set(CALLERID(name)=${VOBIZ_CALLERID_NAME})
 same => n,Set(CLEAN_NUMBER=\${FILTER(0123456789+,\${EXTEN})})
 same => n,NoOp(Cleaned number to dial: \${CLEAN_NUMBER} using CallerID: \${CALLERID(num)})
 same => n,Dial(PJSIP/vobiz-trunk/sip:\${CLEAN_NUMBER}@${VOBIZ_DOMAIN})
 same => n,Hangup()
EOF


# --- websocket_client.conf ---
sudo tee /opt/asterisk-gateway/config/websocket_client.conf > /dev/null << 'EOF'
[dograh]
type = websocket_client
uri = wss://api.dograh.com/api/v1/telephony/ws/ari
protocols = media
tls_enabled = yes
ca_list_file = /etc/ssl/certs/ca-certificates.crt
EOF

# --- ari_proxy.py ---
sudo tee /opt/asterisk-gateway/config/ari_proxy.py > /dev/null << 'EOF'
import socket
import threading
import select
import urllib.parse
import sys

LISTEN_PORT = 8088
ASTERISK_HOST = 'asterisk'
ASTERISK_PORT = 8088

def sanitize_endpoint(endpoint_str):
    try:
        decoded = urllib.parse.unquote(endpoint_str)
        if '/' in decoded:
            tech, resource = decoded.split('/', 1)
            tech = tech.strip()
            
            if tech.upper() in ['LOCAL', 'PJSIP']:
                context = "default"
                number_part = resource
                
                if '@' in resource:
                    number_part, context = resource.split('@', 1)
                
                if number_part.lower().startswith('sip:'):
                    number_part = number_part[4:]
                
                has_plus = number_part.strip().startswith('+') or number_part.startswith(' ')
                digits_only = ''.join(c for c in number_part if c.isdigit())
                
                if len(digits_only) >= 5:
                    # Smart E.164 Normalization
                    if len(digits_only) == 10:
                        cleaned_number = f"+91{digits_only}"
                    elif len(digits_only) == 12 and digits_only.startswith('91'):
                        cleaned_number = f"+{digits_only}"
                    else:
                        prefix = "+" if has_plus else ""
                        cleaned_number = f"{prefix}{digits_only}"
                    
                    new_endpoint = f"Local/{cleaned_number}@{context}"
                    print(f"[ARI Proxy] Normalized & Rewrote endpoint '{endpoint_str}' -> '{new_endpoint}'", flush=True)
                    return new_endpoint
    except Exception as e:
        print(f"[ARI Proxy] Error parsing endpoint '{endpoint_str}': {e}", flush=True)
    return endpoint_str

def handle_client(client_socket):
    try:
        data = client_socket.recv(65536)
        if not data:
            client_socket.close()
            return
    except Exception:
        client_socket.close()
        return

    try:
        parts = data.split(b'\r\n\r\n', 1)
        header_bytes = parts[0]
        body_bytes = parts[1] if len(parts) > 1 else b''
        
        header_text = header_bytes.decode('utf-8', errors='ignore')
        lines = header_text.split('\r\n')
        request_line = lines[0]
        request_parts = request_line.split(' ')
        
        if len(request_parts) >= 2 and request_parts[0] == 'POST' and ('/channels' in request_parts[1] or '/ari/channels' in request_parts[1]):
            method, uri, version = request_parts[0], request_parts[1], request_parts[2]
            
            # 1. Sanitize inside URI query parameters
            url_parsed = urllib.parse.urlparse(uri)
            query_params = urllib.parse.parse_qs(url_parsed.query, keep_blank_values=True)
            
            modified = False
            if 'endpoint' in query_params:
                original_endpoint = query_params['endpoint'][0]
                cleaned_endpoint = sanitize_endpoint(original_endpoint)
                if original_endpoint != cleaned_endpoint:
                    query_params['endpoint'] = [cleaned_endpoint]
                    modified = True
            
            if modified:
                new_query = urllib.parse.urlencode(query_params, doseq=True, quote_via=urllib.parse.quote)
                new_uri = url_parsed.path
                if new_query:
                    new_uri += '?' + new_query
                lines[0] = f"{method} {new_uri} {version}"
                header_text = '\r\n'.join(lines)
                header_bytes = header_text.encode('utf-8')
            
            # 2. Sanitize inside POST body
            content_type = ""
            for line in lines:
                if line.lower().startswith("content-type:"):
                    content_type = line.split(":", 1)[1].strip().lower()
                    break
            
            if body_bytes:
                body_modified = False
                if "application/json" in content_type:
                    import json
                    try:
                        body_json = json.loads(body_bytes.decode('utf-8'))
                        if isinstance(body_json, dict) and 'endpoint' in body_json:
                            original_endpoint = body_json['endpoint']
                            cleaned_endpoint = sanitize_endpoint(original_endpoint)
                            if original_endpoint != cleaned_endpoint:
                                body_json['endpoint'] = cleaned_endpoint
                                body_bytes = json.dumps(body_json).encode('utf-8')
                                body_modified = True
                    except Exception as json_err:
                        print(f"[ARI Proxy] JSON parse error: {json_err}", flush=True)
                elif "application/x-www-form-urlencoded" in content_type:
                    try:
                        body_params = urllib.parse.parse_qs(body_bytes.decode('utf-8'), keep_blank_values=True)
                        if 'endpoint' in body_params:
                            original_endpoint = body_params['endpoint'][0]
                            cleaned_endpoint = sanitize_endpoint(original_endpoint)
                            if original_endpoint != cleaned_endpoint:
                                body_params['endpoint'] = [cleaned_endpoint]
                                body_bytes = urllib.parse.urlencode(body_params, doseq=True, quote_via=urllib.parse.quote).encode('utf-8')
                                body_modified = True
                    except Exception as form_err:
                        print(f"[ARI Proxy] Form urlencode parse error: {form_err}", flush=True)
                
                if body_modified:
                    new_len = len(body_bytes)
                    for i, line in enumerate(lines):
                        if line.lower().startswith("content-length:"):
                            lines[i] = f"Content-Length: {new_len}"
                            break
                    header_text = '\r\n'.join(lines)
                    header_bytes = header_text.encode('utf-8')
            
            data = header_bytes + b'\r\n\r\n' + body_bytes

    except Exception as e:
        print(f"[ARI Proxy] Non-fatal request parsing error: {e}", flush=True)

    # Forward to Asterisk
    asterisk_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        asterisk_socket.connect((ASTERISK_HOST, ASTERISK_PORT))
    except Exception as e:
        print(f"[ARI Proxy] Failed to connect to Asterisk backend: {e}", flush=True)
        client_socket.close()
        return

    try:
        asterisk_socket.sendall(data)
    except Exception as e:
        print(f"[ARI Proxy] Failed to forward initial request: {e}", flush=True)
        client_socket.close()
        asterisk_socket.close()
        return

    # Pipe bidirectional tunnel (works perfectly for both HTTP and WebSockets)
    sockets = [client_socket, asterisk_socket]
    try:
        while True:
            readable, _, exceptional = select.select(sockets, [], sockets, 60)
            if exceptional:
                break
            for sock in readable:
                other_sock = asterisk_socket if sock is client_socket else client_socket
                chunk = sock.recv(8192)
                if not chunk:
                    raise Exception("Connection closed")
                other_sock.sendall(chunk)
    except Exception:
        pass
    finally:
        client_socket.close()
        asterisk_socket.close()

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(128)
    print(f"[ARI Proxy] Sanitizer Proxy listening on port {LISTEN_PORT}...", flush=True)
    
    while True:
        try:
            server_sock, _ = server.accept()
            t = threading.Thread(target=handle_client, args=(server_sock,))
            t.daemon = True
            t.start()
        except KeyboardInterrupt:
            break
        except Exception:
            pass

if __name__ == '__main__':
    main()
EOF

# --- modules.conf ---
sudo tee /opt/asterisk-gateway/config/modules.conf > /dev/null << 'EOF'
[modules]
autoload=yes
load => chan_websocket.so
load => res_http_websocket.so
load => res_pjsip_transport_websocket.so
load => res_websocket_client.so
EOF

# 6. Boot the Docker application
cd /opt/asterisk-gateway
sudo docker-compose down
sudo docker-compose up -d
echo "Deployment successful!"
