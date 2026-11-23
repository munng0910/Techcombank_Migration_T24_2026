# Jenkins Pipeline Specification: OGG Operational Tasks

## 1. Overview
The goal is to create a Jenkins Pipeline based on `jenkins/Jenkinsfile_run_start_service.groovy` that automates running the `op_ogg_actions.sh` script across two site environments: **DC** and **DR**.

---

## 2. Parameter Selection Workflow

### Step 1: Select Target Site
* **Site Selection**: `DC` or `DR` *(refer to `jenkins/Jenkinsfile_run_start_service.groovy`)*

### Step 2: Select Action
Choose one from the list of **8 OGG Actions**:
* `stop_ext`
* `stop_rep`
* `stop_depl`
* `stop_sm`
* `start_ext`
* `start_rep`
* `start_depl`
* `start_sm`

---

## 3. Action Hierarchy & Required Inputs

> **Note on Structure:**
> * Level `1`: Parent Action (Selected OGG Action)
> * Level `2`: Child Parameter Selection (Deployment, Extract, or Replicat list)

### Action Workflows

| Parent Action (`1`) | Step 2 Input | Step 3 Input |
| :--- | :--- | :--- |
| **`stop_ext`** | Choose Deployment (from declared list) | Choose Extract (from declared list) |
| **`stop_rep`** | Choose Deployment (from declared list) | Choose Replicat (from declared list) |
| **`start_ext`** | Choose Extract (from declared list) | N/A |
| **`start_rep`** | Choose Replicat (from declared list) | N/A |
| **`stop_depl`** | Choose Deployment (from declared list) | N/A |
| **`start_depl`** | Choose Deployment (from declared list) | N/A |
| **`stop_sm`** | N/A (ServiceManager level) | N/A |
| **`start_sm`** | N/A (ServiceManager level) | N/A |

---

## 4. Declared Entity Lists Required in Pipeline

The pipeline needs to define and maintain declared lists for the following entities:

1. **Deployments List** (e.g., `ogg_oracle01`, `ogg_oracle02`, `ogg_oracle03`, ...)
2. **Extracts List** (e.g., `EXT24P`, `EXT25P`, ...)
3. **Replicats List** (e.g., `REP24P`, `REP25P`, ...)

# New update 1.
if in `op_ogg_actions.sh` use `OGG_INSECURE_TLS=false` we will need to export `OGG_CLIENT_TLS_CAPATH` in session run script. Example:
```
export OGG_CLIENT_TLS_CAPATH=/u01/OracleGoldenGate/OGG_Certs/RootCA_cert.pem;   sh op_ogg_actions.sh start_rep ogg_daa03 OGGHUB_CORELIVE RKKPL01
```

if set `OGG_INSECURE_TLS=true` we will do not need to export `OGG_CLIENT_TLS_CAPATH`.

# Pipeline Requirements - Update 2

## Current Action Parameters

Currently, the pipeline actions include the following parameters:

- **ENVIRONMENT**: `pt`
- **TARGET_SITE**: `DR`
- **OGG_ACTION**: `start_ext`
- **DEPLOYMENT**: `ogg_oracle03`
- **CREDENTIAL_NAME**: `OGGHUB_CORELIVE`
- **EXTRACT**: `EXT24P`

By default, `ENVIRONMENT`, `TARGET_SITE`, and `OGG_ACTION` are always required selections.

---

## Dynamic Dropdown Display Logic

Currently, the Jenkins pipeline displays all dropdown selections simultaneously. The target behavior for parameter visibility is as follows:

- **Full Dropdown Visibility (`start_ext`, `stop_ext`, `start_rep`, `stop_rep`)**:
  - Show all selection parameters (including `DEPLOYMENT`, `CREDENTIAL_NAME`, and `EXTRACT`/`REPLICAT`).

- **Deployment Actions (`start_depl`, `stop_depl`)**:
  - Hide the `EXTRACT` and `REPLICAT` selection dropdowns.

- **ServiceManager Actions (`start_sm`, `stop_sm`)**:
  - Hide `EXTRACT`/`REPLICAT`, `DEPLOYMENT`, and `CREDENTIAL_NAME` selection dropdowns (only keep `ENVIRONMENT`, `TARGET_SITE`, and `OGG_ACTION`).


# Pipeline Requirements - Update 3

## Overview

The `op_ogg_actions.sh` script has been updated to support wildcard parameters (`'*'`).

---

## Script Execution Syntax Examples

- **`stop_rep` action with wildcard process:**
  ```bash
  bash op_ogg_actions.sh stop_rep ogg_daa03 OGGHUB_CORELIVE '*'
  ```
- **`start_depl` action with wildcard deployment:**
  ```bash
  bash op_ogg_actions.sh start_depl '*' OGGHUB_CORELIVE
  ```
  
**Pipeline Requirements**

    - Adjust the Jenkins pipeline to allow * (wildcard) as a valid input parameter.

    - Ensure that the pipeline formats and passes '*' as a literal string argument to op_ogg_actions.sh during execution.
