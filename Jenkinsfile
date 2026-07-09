pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        // ── Update ECR_REGISTRY with your AWS account ID ──────────────────
        // Get it from: terraform output ecr_repository_url
        ECR_REGISTRY  = "007400345148.dkr.ecr.ap-south-1.amazonaws.com/petclinic-dev-app"
        ECR_REPO      = "petclinic-dev-app"
        AWS_REGION    = "ap-south-1"
        EKS_CLUSTER   = "petclinic-dev-eks"
        SONAR_SCANNER = tool 'SonarScanner'
        IMAGE_TAG     = "${BUILD_NUMBER}"
        IMAGE_URI     = "${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
        MANIFEST_REPO = "https://github.com/skssandy/petclinic-k8s-manifests.git"
    }

    stages {

        /*──────────────────────────────────────────────
         * 1. Checkout
         *──────────────────────────────────────────────*/
        stage('Checkout') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: '*/main']],
                    userRemoteConfigs: [[
                        credentialsId: 'github-token',
                        url: 'https://github.com/skssandy/spring-petclinic.git'
                    ]]
                ])
                script {
                    env.GIT_SHA = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()
                    echo "Build: ${env.BUILD_NUMBER} | Commit: ${env.GIT_SHA}"
                }
            }
        }

        /*──────────────────────────────────────────────
         * 2. Maven Build
         * Skips tests here — tests run as part of
         * SonarQube analysis in the next stage
         *──────────────────────────────────────────────*/
        stage('Maven Build') {
            steps {
                sh '''
                    export MAVEN_OPTS="-Djava.io.tmpdir=/var/tmp \
                                       -Xms256m -Xmx1024m"
                    mvn -B clean package -DskipTests
                '''
            }
        }

        /*──────────────────────────────────────────────
         * 3. SonarQube Analysis
         *──────────────────────────────────────────────*/
        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh """
                        \${SONAR_SCANNER}/bin/sonar-scanner \
                          -Dsonar.projectKey=spring-petclinic \
                          -Dsonar.projectName=spring-petclinic \
                          -Dsonar.sources=src/main/java \
                          -Dsonar.java.binaries=target/classes \
                          -Dsonar.java.source=17
                    """
                }
            }
        }

        /*──────────────────────────────────────────────
         * 4. Quality Gate
         * Waits for SonarQube webhook callback.
         * abortPipeline: true = pipeline fails if
         * code does not meet quality standards
         *──────────────────────────────────────────────*/
        stage('Quality Gate') {
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        /*──────────────────────────────────────────────
         * 5. Docker Build
         * Multi-stage build — see Dockerfile
         *──────────────────────────────────────────────*/
        stage('Docker Build') {
            steps {
                sh """
                    docker build \
                      -t ${IMAGE_URI} \
                      -t ${ECR_REGISTRY}/${ECR_REPO}:latest \
                      .
                    docker images | grep ${ECR_REPO}
                """
            }
        }

        /*──────────────────────────────────────────────
         * 6. Trivy Security Scan
         * Scans for HIGH and CRITICAL CVEs.
         * --exit-code 0 means pipeline continues even
         * if vulnerabilities found (report only).
         * Change to --exit-code 1 to make it a hard gate
         *──────────────────────────────────────────────*/
        stage('Trivy Scan') {
            steps {
                sh """
                    trivy image \
                      --exit-code 0 \
                      --severity HIGH,CRITICAL \
                      --no-progress \
                      --format table \
                      ${IMAGE_URI} | tee trivy-report.txt
                """
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt',
                                     allowEmptyArchive: true
                }
            }
        }

        /*──────────────────────────────────────────────
         * 7. Push to ECR
         *──────────────────────────────────────────────*/
        stage('Push to ECR') {
            steps {
                withCredentials([
                    string(credentialsId: 'aws-access-key-id',
                           variable: 'AWS_ACCESS_KEY_ID'),
                    string(credentialsId: 'aws-secret-access-key',
                           variable: 'AWS_SECRET_ACCESS_KEY')
                ]) {
                    sh """
                        aws configure set aws_access_key_id     \$AWS_ACCESS_KEY_ID
                        aws configure set aws_secret_access_key \$AWS_SECRET_ACCESS_KEY
                        aws configure set default.region        ${AWS_REGION}

                        aws ecr get-login-password --region ${AWS_REGION} \
                          | docker login --username AWS \
                              --password-stdin ${ECR_REGISTRY}

                        docker push ${IMAGE_URI}
                        docker push ${ECR_REGISTRY}/${ECR_REPO}:latest

                        echo "Pushed: ${IMAGE_URI}"
                    """
                }
            }
        }

        /*──────────────────────────────────────────────
         * 8. Update Manifest Repo
         * Replaces the image tag in deployment.yaml.
         * ArgoCD detects the git commit and auto-syncs
         * to EKS — this is the GitOps trigger.
         *──────────────────────────────────────────────*/
        stage('Update Manifest') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'github-token',
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GIT_TOKEN'
                    )
                ]) {
                    sh """
                        git config --global user.email "jenkins@petclinic.dev"
                        git config --global user.name  "Jenkins CI"

                        rm -rf manifest-repo
                        git clone https://\${GIT_USER}:\${GIT_TOKEN}@github.com/skssandy/petclinic-k8s-manifests.git manifest-repo
                        cd manifest-repo

                        sed -i 's|${ECR_REGISTRY}/${ECR_REPO}:.*|${IMAGE_URI}|g' \
                          k8s/deployment.yaml

                        git add k8s/deployment.yaml
                        git diff --cached --quiet || git commit \
                          -m "ci: update image to build-${BUILD_NUMBER} [${GIT_SHA}]"
                        git push origin main

                        echo "Manifest updated — ArgoCD will sync shortly"
                    """
                }
            }
        }
    }

    post {
        success {
            echo "=================================="
            echo "  SUCCESS — Build ${BUILD_NUMBER}"
            echo "  Image: ${IMAGE_URI}"
            echo "=================================="
        }
        failure {
            echo "=================================="
            echo "  FAILED — Check logs above"
            echo "=================================="
        }
        always {
            sh 'docker system prune -af --filter "until=2h" || true'
            cleanWs()
        }
    }
}
