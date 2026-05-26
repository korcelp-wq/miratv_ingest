# MiraTV Database Components: Catalog & Locations

## Purpose
This document catalogs all major database components, their schema files, and their locations in the MiraTV system. It serves as a reference for onboarding, troubleshooting, and integration.

---

## 1. Database Schemas & Locations

| Database Name                        | Purpose/Scope                        | Schema File Location                                      |
|--------------------------------------|--------------------------------------|-----------------------------------------------------------|
| xpdgxfsp_content                     | Core IPTV catalog (live, VOD, series)| /xpdgxfsp_content.sql                                     |
| xpdgxfsp_ip                          | Device activation & MAC binding      | /xpdgxfsp_ip.sql                                          |
| xpdgxfsp_ops                         | Job scheduling & pipeline operations | /xpdgxfsp_ops.sql                                         |
| xpdgxfsp_lake_vector                 | Lake Knowledge DB (state tracking)   | /xpdgxfsp_lake_vector.sql                                 |
| xpdgxfsp_i_m_g_vector_context        | Image/Metadata governance vector     | /xpdgxfsp_i_m_g_vector_context.sql                        |
| xpdgxfsp_inhibitor_govenor_matrix    | Architectural rules & compliance     | /xpdgxfsp_inhibitor_govenor_matrix.sql                    |
| xpdgxfsp_callosum_matrix             | Cross-component orchestration        | /xpdgxfsp_callosum_matrix.sql                             |
| PCDE_memory                          | Registry for operational instructions| /miratv_ingest/pcde_procedure_registry_create.sql          |

---

## 2. Registry Table Example (PCDE_memory)
- Table: `pcde_procedure_registry`
- Schema: See /miratv_ingest/pcde_procedure_registry_create.sql and /miratv_ingest/pcde_procedure_registry_alter.sql

---

## 3. How to Find/Update Schemas
- All schema files are in the project root or /miratv_ingest.
- For new tables, add a .sql file in /miratv_ingest and document in this guide.
- For changes, update the .sql and note the change in a changelog section.

---

## 4. Related Guides
- See also: PCDE_memory_registry_upload_guide.md, PCDE_memory_registry_upload_quickstart.md

---

## 5. Contact
For schema or DB issues, contact the system architect or DB owner.
