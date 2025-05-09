#!/bin/bash

# ========= CONFIGURATION =========
KEY_NAME="ansible-master-play" #public_key
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem" #private_key
SECURITY_GROUP="ansible-flask-sg"
INSTANCE_NAME="flask-student-app"
INSTANCE_TYPE="t2.micro"
REGION="us-west-2"
AMI_ID="ami-07b0c09aab6e66ee9"
ANSIBLE_USER="ubuntu"
REPO_URL="https://github.com/bongodev/flask-student-attendance-app.git"
APP_DIR="/var/www/flask-student-attendance-app"


# ========= STEP 1: Create Key Pair if not exists =========
if [ ! -f "$KEY_PATH" ]; then
  echo "[+] Creating SSH key pair..."
  aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
else
  echo "SSH key already exists."
fi

# ========= STEP 2: Create Security Group =========
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$SECURITY_GROUP" --query 'SecurityGroups[*].GroupId' --output text)
if [ -z "$SG_ID" ]; then
  echo "[+] Creating security group..."
  SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP" \
    --description "Allow SSH and HTTP access" --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0
else
  echo "[i] Security group already exists."
fi

# ========= STEP 3: Launch EC2 Instance =========
echo "[+] Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "[i] Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"


# ========= STEP 4: Get Public IP =========
IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "[+] Instance IP: $IP"

# ========= STEP 5: Wait for SSH =========
echo "[i] Waiting for SSH to be ready..."
sleep 25

# ========= STEP 6: Install Ansible Locally if the host machine doesn't have it (Optional) =========
# if ! command -v ansible &> /dev/null; then
#   echo "[+] Installing Ansible..."
#   sudo apt update
#   sudo apt install -y ansible
# fi

# ========= STEP 7: Create Ansible Inventory =========
echo "[+] Writing Ansible inventory..."
cat > hosts.ini <<EOF
[Servers]
$IP ansible_user=$ANSIBLE_USER ansible_ssh_private_key_file=$KEY_PATH ansible_python_interpreter=/usr/bin/python3
EOF

# ========= STEP 8: Create Ansible Playbook =========
echo "[+] Creating Ansible playbook..."
cat > deploy_flask_app.yml <<EOF
---
- name: Deploy Student Attenattendance App with Docker Compose v2
  hosts: Servers
  become: yes

  vars:
    app_dir: $APP_DIR
    repo_url: $REPO_URL
    item: docker.io


  tasks:

    - name: Install prerequisites for Docker
      apt:
        name: "{{ item }}"
        state: present
        update_cache: yes
      loop:
        - apt-transport-https
        - ca-certificates
        - curl
        - software-properties-common

    - name: Add Docker's official GPG_key
      apt_key:
        url: https://download.docker.com/linux/ubuntu/gpg
        state: present

    - name: Add Docker APT repository
      apt_repository:
        repo: deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ ansible_facts['lsb']['codename'] }} stable
        state: present

    - name: Update APT package index after adding Docker repository
      apt:
        update_cache: yes

    - name: Install Docker Engine and Docker Compose v2
      apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-compose-plugin
        state: present
        update_cache: yes

    - name: Ensure Docker service is started and enabled
      service:
        name: docker
        state: started
        enabled: yes

    - name: Install Git
      apt:
        name: git
        state: present

    - name: Ensure application directory exists
      file:
        path: "{{ app_dir }}"
        state: directory
        mode: '0755'

    - name: Clone the latest code from repository
      git:
        repo: "{{ repo_url }}"
        dest: "{{ app_dir }}"
        version: main
        force: yes

    - name: Build and start Docker containers using Docker Compose v2
      command: docker compose up -d --build
      args:
        chdir: "{{ app_dir }}"

    - name: Verify that the containers are running
      command: docker ps
      args:
        chdir: "{{ app_dir }}"
EOF

# ========= STEP 9: Run Ansible Playbook =========
echo "[+] Running Ansible playbook..."
ansible-playbook -i hosts.ini deploy_flask_app.yml

echo "Deployment completed."
echo "Your Flask app should be available at: $IP:5000"
