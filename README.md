# Asterisk Voice AI Gateway for Dograh & Vobiz SIP Trunk

An enterprise-grade, plug-and-play Asterisk PBX gateway integrated with **Dograh Voice AI** and **Vobiz SIP Trunk**. This gateway enables automated outbound cold calling, lead generation, and interactive AI voice agent calls with E.164 phone number normalization and custom CallerID overrides.

---

## 🏗️ System Architecture

```
                                  +------------------------------------+
                                  |         GCP Virtual Machine        |
                                  |          (35.184.138.113)          |
                                  |                                    |
+------------------+   ARI/REST   |  +--------------------+            |        SIP INVITE       +------------------+
|                  | ------------>|  | ARI Sanitizer Proxy|            | ----------------------> |                  |
|    Dograh AI     |              |  |    (Port 8088)     |            |                         |    Vobiz SIP     |
|    Dashboard     |              |  +---------+----------+            |                         |      Trunk       |
|                  |              |            | Localhost             |                         | (455bdb01.sip...)|
+------------------+              |            v                       |                         +--------+---------+
         ^                        |  +--------------------+            |                                  |
         |       Media Stream     |  |  Asterisk PBX      |            |                                  | PSTN
         +=======================>|  |  (Docker Container)|            |                                  v
                    WSS           |  +--------------------+            |                         +------------------+
                                  +------------------------------------+                         |  Customer Phone  |
                                                                                                 +------------------+
```

1. **Dograh Voice AI** triggers an outbound call via Asterisk's Asterisk REST Interface (ARI).
2. **ARI Sanitizer Proxy** intercepts the request, dynamically parses the payload (JSON or URL-encoded), normalizes the phone number format (E.164), and rewrites direct PJSIP requests into Asterisk Local Channel routing.
3. **Asterisk PBX** applies dialplan rules (`extensions.conf`), injects authorized Vobiz CallerID/headers, and places the outbound SIP call.
4. **Vobiz Gateway** routes the call to the destination handset.
5. **Dograh Voice AI** establishes a high-performance audio WebSocket connection with Asterisk to power the live voice agent conversation.

---

## 🌟 Key Features

* **Smart E.164 Normalization**: Automatically converts 10-digit Indian numbers (e.g. `7989604033`) into `+917989604033` and normalizes formats containing spaces/hyphens.
* **SIP Authorization Header Enforcement**: Standardizes outbound headers (`From` and `CallerID`) to registered Trunk attributes (`+918065481144`), preventing `403 Forbidden` credential rejections.
* **Automatic PJSIP-to-Local Channel Rewriting**: Translates outbound dials from direct PJSIP requests into dialplan-routed Local Channels (`Local/+91...@default`), rendering dialing 100% plug-and-play from the Dograh dashboard.
* **Containerized Infrastructure**: Runs inside ultra-lightweight Docker containers orchestrated with Docker-Compose.

---

## 📂 Codebase Directory Structure

```
├── .gitignore                    # Git file exclusions
├── docker-compose.yml            # Multi-container orchestration (Asterisk & Proxy)
├── deploy_gcp.sh                 # Fully-automated GCP VM deployment script
├── vobiz_to_dograh_setup.md      # Detailed engineering manual
└── config/
    ├── ari.conf                  # ARI user credentials
    ├── ari_proxy.py              # E.164 sanitizer & rewrite HTTP proxy
    ├── extensions.conf           # Dialplan rules & header injectors
    ├── http.conf                 # Internal Asterisk HTTP server binding
    ├── modules.conf              # Module loader configuration
    ├── pjsip.conf                # Trunk registration, authentication, & endpoints
    └── websocket_client.conf     # WebSocket client connections for media streaming
```

---

## 🚀 Deployment Guide (GCP VM Setup)

Deployment is completely automated. To launch the gateway onto any standard Debian/Ubuntu VM (such as GCP):

### Step 1: Clone the Codebase
SSH into your GCP VM instance and clone this repository:
```bash
git clone https://github.com/dineshreddy8742/asterisk-telephony.git /opt/asterisk-gateway
cd /opt/asterisk-gateway
```

### Step 2: Make the Script Executable & Run
Run the master deploy script. It will automatically update the OS, install Docker/Docker-Compose, configure folders, write configuration templates, and launch the services:
```bash
chmod +x deploy_gcp.sh
sudo ./deploy_gcp.sh
```

### Step 3: Verify the Running Containers
Check that both containers are running properly:
```bash
sudo docker ps
```
You should see:
* `asterisk-dograh-gateway` (running Asterisk)
* `asterisk-ari-proxy` (running the Python sanitizer)

---

## 🎛️ Connecting Dograh Voice AI to your Gateway

To activate your voice agents through this gateway, log in to the **Dograh Dashboard** and configure the Telephony settings as follows:

| Parameter | Configuration Value |
| :--- | :--- |
| **ARI Endpoint** | `http://35.184.138.113:8088` *(or your VM's public IP)* |
| **App Name** | `dograh` |
| **App Password** | `your_ari_password_here (from .env)` |
| **WS Client Name** | `dograh` |

### Adding Outbound Numbers
In the Dograh portal:
1. Navigate to **Telephony** > **Asterisk ARI**.
2. Click **Add phone number**.
3. Set the Address to `Local/${NUMBER}@default` and register it as an active Outbound path.


---

## 🛠️ Operational Commands & Debugging

If you need to view raw logs, troubleshoot connections, or restart components, use these standard terminal commands:

### Read Real-time SIP Call Flow & Registrations
```bash
# Enter Asterisk CLI
sudo docker exec -it asterisk-dograh-gateway asterisk -rvvvvv

# Inside Asterisk CLI:
# Show registration status
pjsip show registrations

# Enable live SIP logger to inspect headers (INVITE/TRYING/OK)
pjsip set logger on
```

### View Python Sanitizer Proxy Logs
To trace how incoming call requests from Dograh are being parsed, sanitized, and normalized:
```bash
sudo docker logs asterisk-ari-proxy --tail 100 -f
```

### Restart Services
```bash
cd /opt/asterisk-gateway
sudo docker-compose down
sudo docker-compose up -d
```
