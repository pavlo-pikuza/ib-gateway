# IB-Gateway

A project for automated deployment and launch of **Interactive Brokers Gateway** in a remote environment using Docker Compose.

📦 **Prebuilt Image:** [`ghcr.io/gnzsnz/ib-gateway`](https://ghcr.io/gnzsnz/ib-gateway)  

---

## 📋 Prerequisites
Before using this project, you must:

1. **Have an active Interactive Brokers (IBKR) account** — this is required to authenticate and use the gateway.  
2. **Add your remote server’s IP address to the list of trusted IPs in IBKR account settings** at least **24 hours before installation and startup**.  
   - This step is mandatory; otherwise, the gateway connection will be rejected by IBKR.

---

## 📌 Features
- Installs Docker and Docker Compose on a remote server (Ubuntu 22.04).
- Creates a dedicated `ibgateway` user with a secure password.
- Copies required files (`.env`, `docker-compose.yml`) to the remote machine.
- Automatically launches the service via Docker Compose.
- Configures the server’s timezone according to `.env`.
- Hardens SSH security (disables root access, allows only `ibgateway`).

---

## ⚙️ Project Structure
```
IB-GATEWAY/
├── logs/                          # Script execution logs
├── .env                           # Personal environment variables (not committed)
├── .env.example                   # Configuration example
├── .gitignore                     # Ignored files
├── docker-compose.yml             # Service configuration
├── ibgateway_password.txt         # Generated user password (automatically created)
├── remote_server_setup.sh         # Main project script
```

---

## 🖥 Main Script — `remote_server_setup.sh`
This is the **core entry point** of the project.  
It performs the following steps on a given remote server:

1. **Checks prerequisites** — verifies that `sshpass` is installed locally.  
2. **Validates configuration** — ensures `.env` and `docker-compose.yml` are present.  
3. **Installs Docker & Docker Compose** on the remote machine.  
4. **Creates a dedicated user `ibgateway`** with a secure password (saved locally to `ibgateway_password.txt`).  
5. **Sets up the working directory** `/opt/ib-gateway` and assigns proper permissions.  
6. **Configures timezone** according to the `TZ` value from `.env`.  
7. **Copies `.env` and `docker-compose.yml`** to the remote server.  
8. **Builds and starts containers** using Docker Compose (either plugin or standalone).  
9. **Hardens SSH security** — disables root login, allows only `ibgateway`, keeps password authentication.  

---

## 📄 `.env.example` File
Example:
```env
TZ=America/New_York
API_KEY=your_api_key_here
API_SECRET=your_api_secret_here
```
> Before running the script, create `.env` based on `.env.example` and fill in real credentials.

---

## 🚀 Installation & Launch

### 1. Prepare the local machine
Install `sshpass`:
```bash
sudo apt install sshpass
```

### 2. Configure `.env`
Copy and edit:
```bash
cp .env.example .env
nano .env
```

### 3. Run remote deployment
```bash
chmod +x remote_server_setup.sh
./remote_server_setup.sh <REMOTE_IP> <ROOT_PASSWORD>
```
Example:
```bash
./remote_server_setup.sh 192.168.0.100 myRootPass
```

---

## 🛠 Useful Commands
Check if the container is running:
```bash
sshpass -f ./ibgateway_password.txt ssh -o StrictHostKeyChecking=no ibgateway@<REMOTE_IP> 'docker ps'
```

View Docker logs:
```bash
sshpass -f ./ibgateway_password.txt ssh -o StrictHostKeyChecking=no ibgateway@<REMOTE_IP> 'journalctl -u docker -n 200 --no-pager'
```

---

## 🔒 Security
- `.env` and `ibgateway_password.txt` are in `.gitignore`.
- Root SSH access is disabled.
- Only the `ibgateway` user is allowed to log in.

---

## 📜 License
Specify the license, for example:
```
MIT License
```
