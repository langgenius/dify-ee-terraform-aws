---
config:
  layout: elk
---
flowchart TB
 subgraph KubeSystem["⚙️ kube-system namespace"]
        AWSLBC1["🎯 aws-load-balancer-controller<br>Pod 1<br>Managing ALB/NLB"]
        AWSLBC2["🎯 aws-load-balancer-controller<br>Pod 2<br>High Availability"]
        AWSNode["📡 aws-node<br>VPC CNI Plugin<br>Pod Networking"]
        CoreDNS1["🔍 coredns<br>DNS Server 1<br>Service Discovery"]
        CoreDNS2["🔍 coredns<br>DNS Server 2<br>High Availability"]
        KubeProxy["🔀 kube-proxy<br>Network Proxy<br>Service Routing"]
  end
 subgraph ActivePlugins["⚡ Active Plugin Instances<br>🟢 Dynamic - Created on Install"]
        TongyiPlugin["🤖 Plugin Example 1<br>langgenius-tongyi<br>Port: 8080<br>📌 Created via CRD"]
        OpenAIPlugin["🤖 Plugin Example 2<br>langgenius-openai<br>Port: 8080<br>📌 Created via CRD"]
  end
 subgraph PluginBuilds["🏗️ Plugin Build Jobs<br>🔨 Dynamic - Kaniko Builder"]
        PluginBuildJob["📦 Plugin Build Job<br>Kaniko Image Builder<br>📌 Created on Plugin Install<br>Pushes to ECR/Registry"]
  end
 subgraph SSRFProtection["🛡️ SSRF Protection Layer"]
        SSRFProxy["🛡️ dify-ssrf-proxy<br>SSRF Proxy Protection<br>Port: 3128<br>Squid HTTP Proxy"]
        Sandbox["📦 dify-sandbox<br>Code Execution Sandbox<br>Port: 8194<br>Protected by SSRF Proxy"]
  end
 subgraph InClusterDBs["🗄️ In-Cluster Database Services<br>🔄 Can be replaced by external services"]
        PostgreSQLCluster[("🗄️ PostgreSQL<br>Primary Database Service<br>Running in Cluster")]
        RedisMaster[("⚡ Redis Master<br>Primary Cache Node<br>Port: 6379")]
        RedisReplicas[("⚡ Redis Replicas<br>n * Replica Nodes<br>High Availability")]
        VectorDBCluster[("🔍 Qdrant / OpenSearch<br>Vector Search Service<br>Qdrant: Local | OpenSearch: AWS")]
  end
 subgraph DifyNamespace["📁 dify namespace"]
        Gateway["🚪 dify-gateway<br>Caddy Gateway<br>Port: 80/443"]
        Web["🌐 dify-web<br>Frontend Application<br>Port: 3000"]
        API["🔌 dify-api<br>Backend API<br>Port: 5001"]
        EnterpriseFE["💼 dify-enterprise-frontend<br>Enterprise Frontend<br>Port: 3000"]
        Enterprise["🏢 dify-enterprise<br>Enterprise Core Service<br>Port: 8082"]
        EnterpriseAudit["📋 dify-enterprise-audit<br>Enterprise Audit Service<br>Port: 8083"]
        Worker["⚙️ dify-worker<br>Async Task Processor<br>Port: -"]
        WorkerBeat["⏰ dify-worker-beat<br>Scheduled Task Manager<br>Port: -"]
        PluginDaemon["🔌 dify-plugin-daemon<br>Plugin Execution Engine<br>Port: 5002 + 5003<br>Direct Plugin Runner"]
        PluginConnector["🔗 dify-plugin-connector<br>Plugin Orchestrator<br>Port: 5004<br>K8s Plugin Lifecycle"]
        PluginManager["📦 dify-plugin-manager<br>Plugin Management Service<br>Port: 8084 + 9084<br>Plugin Registry &amp; Status"]
        ActivePlugins
        PluginBuilds
        SSRFProtection
        Unstructured["📄 dify-unstructured<br>Document Processing<br>Port: 8000<br>⚠️ Optional Component"]
        MinIO["💾 dify-minio<br>Standby Object Storage<br>Port: 9000<br>Unused if S3 is Online"]
        MinIOConsole["🖥️ MinIO Web Console<br>Management Interface<br>Port: 9001<br>Internal Access Only"]
        CRDController["🎛️ dify-crd-controller<br>Plugin CRD Controller<br>Port: -<br>Status: Running"]
        InClusterDBs
  end
 subgraph EKS["🚀 AWS EKS Cluster (Private Subnets)"]
        KubeSystem
        DifyNamespace
  end
 subgraph VPCManagedServices["☁️ VPC Internal AWS Services<br>🔐 Private Subnets"]
        RDS[("🗄️ AWS RDS Aurora PostgreSQL<br>Private Subnets")]
        ElastiCache[("⚡ AWS ElastiCache<br>Redis Cache<br>Private Subnets")]
        OpenSearch[("🔍 AWS OpenSearch<br>Vector Search Engine<br>Private Subnets")]
  end
 subgraph ExternalAWSServices["☁️ External AWS Services<br>🌐 Global/Regional Services"]
        S3[("💾 AWS S3<br>Object Storage Service<br>File & Document Storage")]
        ECR["📦 AWS ECR<br>Plugin Image Registry<br>Container Images"]
  end
 subgraph SSL["🔒 SSL/TLS Security"]
        ACMCert["📜 AWS Certificate Manager<br>ACM Certificate<br>*.dify.local"]
  end
 subgraph VPC["🌐 AWS VPC (10.0.0.0/16)<br>Private Network Boundary"]
        ALB["AWS Application Load Balancer<br>SSL Certificate: ACM<br>Public Subnets"]
        EKS
        VPCManagedServices
        SSL
        AWS_API["☁️ AWS APIs<br>EC2, ELB, Route53<br>Service Endpoints"]
  end
    Internet["🌐 Internet"]
    User["👤 User"] --> Internet
    Internet --> ALB
    ALB -- "console.dify.local<br>Management Console" --> Gateway
    ALB -- "api.dify.local<br>API Endpoints" --> Gateway
    ALB -- "app.dify.local<br>Application Interface" --> Gateway
    ALB -- "upload.dify.local<br>File Upload" --> Gateway
    ALB -- "enterprise.dify.local<br>Enterprise Features" --> Gateway
    AWSLBC1 -.-> ALB & AWS_API
    AWSLBC2 -.-> ALB & AWS_API
    CoreDNS1 -.-> Gateway
    CoreDNS2 -.-> Gateway
    KubeProxy -.-> Gateway
    AWSNode -.-> Gateway & AWS_API
    ALB -.-> ACMCert
    Gateway -- "from console.dify.local & app.dify.local" --> Web
    Gateway -- "from api.dify.local" --> API
    Gateway -- "from enterprise.dify.local" --> EnterpriseFE & Enterprise
    Gateway -- "from upload.dify.local" --> API
    API --> Enterprise & EnterpriseAudit & Worker & WorkerBeat & PluginDaemon & SSRFProxy & Unstructured
    PluginDaemon -- Plugin Execution Requests --> TongyiPlugin & OpenAIPlugin
    PluginDaemon -- "Plugin Installation Request<br>+ Plugin Info" --> PluginConnector
    PluginDaemon --> PluginManager
    PluginConnector -- Pod Management --> TongyiPlugin & OpenAIPlugin
    PluginConnector --> PluginManager
    PluginConnector -. Creates Build Jobs .-> PluginBuildJob
    PluginConnector -. Pushes Images .-> ECR
    CRDController -. Manages Plugin CRDs .-> PluginConnector
    CRDController -. Monitors Plugin Status .-> TongyiPlugin & OpenAIPlugin
    SSRFProxy -- Reverse Proxy --> Sandbox
    Sandbox -- HTTP_PROXY: 3128 --> SSRFProxy
    MinIO -. "Admin Interface<br>Debug Access" .-> MinIOConsole
    API -.-> PostgreSQLCluster & RedisMaster & VectorDBCluster
    RedisMaster --> RedisReplicas
    API -. "File Storage<br>& Document Upload" .-> S3
    PluginConnector -.-> PostgreSQLCluster
    PluginConnector -. "Plugin Assets<br>& Build Artifacts" .-> S3
    Worker -. "Background Task<br>File Processing" .-> S3
    WorkerBeat -. "Scheduled Task<br>File Operations" .-> S3
    PluginBuildJob -. "Plugin Build<br>Image Storage" .-> S3
    PluginBuildJob -. "Fallback Storage<br>Not Used if S3 is Online" .-> MinIO
    PostgreSQLCluster -. "Switchable<br>External/Internal" .- RDS
    RedisMaster -. "Switchable<br>External/Internal" .- ElastiCache
    VectorDBCluster -. "Switchable<br>External/Internal" .- OpenSearch
    MinIO -. "Standby Alternative<br>S3 Fallback Option" .- S3
    SSRFProxy -- Filtered Internet Access<br>via NAT Gateway --> Internet
     AWSLBC1:::infrastructure
     AWSLBC2:::infrastructure
     AWSNode:::infrastructure
     CoreDNS1:::infrastructure
     CoreDNS2:::infrastructure
     KubeProxy:::infrastructure
     TongyiPlugin:::activePlugin
     OpenAIPlugin:::activePlugin
     PluginBuildJob:::buildJob
     SSRFProxy:::security
     Sandbox:::security
     PostgreSQLCluster:::cluster
     RedisMaster:::cluster
     RedisReplicas:::cluster
     VectorDBCluster:::cluster
     Gateway:::security
     Web:::frontend
     API:::backend
     EnterpriseFE:::frontend
     Enterprise:::backend
     EnterpriseAudit:::backend
     Worker:::backend
     WorkerBeat:::backend
     PluginDaemon:::plugin
     PluginConnector:::plugin
     PluginManager:::plugin
     ActivePlugins:::pluginContainer
     PluginBuilds:::buildContainer
     SSRFProtection:::securityContainer
     Unstructured:::external
     MinIO:::storage
     MinIOConsole:::storage
     CRDController:::plugin
     InClusterDBs:::dbContainer
     KubeSystem:::kubeSystemContainer
     DifyNamespace:::difyNamespaceContainer
     RDS:::storage
     ElastiCache:::storage
     OpenSearch:::storage
     S3:::storage
     ECR:::aws
     ACMCert:::ssl
     ALB:::aws
     Internet:::external
     EKS:::eksContainer
     VPCManagedServices:::vpcServicesContainer
     ExternalAWSServices:::externalServicesContainer
     SSL:::sslContainer
     AWS_API:::aws
     User:::external
     VPC:::vpcContainer
    classDef frontend fill:#1e3a8a,stroke:#60a5fa,stroke-width:2px,color:#ffffff
    classDef backend fill:#581c87,stroke:#a855f7,stroke-width:2px,color:#ffffff
    classDef storage fill:#14532d,stroke:#22c55e,stroke-width:2px,color:#ffffff
    classDef security fill:#ea580c,stroke:#fb923c,stroke-width:3px,color:#ffffff
    classDef plugin fill:#be185d,stroke:#f472b6,stroke-width:2px,color:#ffffff
    classDef infrastructure fill:#374151,stroke:#9ca3af,stroke-width:2px,color:#ffffff
    classDef aws fill:#dc2626,stroke:#f87171,stroke-width:2px,color:#ffffff
    classDef external fill:#1f2937,stroke:#d1d5db,stroke-width:2px,color:#ffffff
    classDef ssl fill:#059669,stroke:#10b981,stroke-width:2px,color:#ffffff
    classDef cluster fill:#1d4ed8,stroke:#3b82f6,stroke-width:3px,color:#ffffff
    classDef activePlugin fill:#059669,stroke:#10b981,stroke-width:3px,color:#ffffff
    classDef buildJob fill:#d97706,stroke:#f59e0b,stroke-width:2px,color:#ffffff
    classDef vpcContainer fill:#f0f4ff,stroke:#3b82f6,stroke-width:4px,color:#1f2937
    classDef eksContainer fill:#f0f7ff,stroke:#60a5fa,stroke-width:3px,color:#1f2937
    classDef difyNamespaceContainer fill:#f8faff,stroke:#93c5fd,stroke-width:3px,color:#1f2937
    classDef kubeSystemContainer fill:#f5f8ff,stroke:#60a5fa,stroke-width:3px,color:#1f2937
    classDef vpcServicesContainer fill:#f0f4ff,stroke:#3b82f6,stroke-width:3px,color:#1f2937
    classDef externalServicesContainer fill:#fef3f2,stroke:#f87171,stroke-width:3px,color:#1f2937
    classDef sslContainer fill:#f5f9ff,stroke:#60a5fa,stroke-width:2px,color:#1f2937
    classDef pluginContainer fill:#f8fbff,stroke:#93c5fd,stroke-width:2px,color:#1f2937
    classDef buildContainer fill:#f5f9ff,stroke:#60a5fa,stroke-width:2px,color:#1f2937
    classDef securityContainer fill:#f0f7ff,stroke:#3b82f6,stroke-width:2px,color:#1f2937
    classDef dbContainer fill:#f5f8ff,stroke:#60a5fa,stroke-width:2px,color:#1f2937
