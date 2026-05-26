-- Update pcde_procedure_registry table to add registry fields for CVI documentation
ALTER TABLE pcde_procedure_registry
    ADD COLUMN source_db VARCHAR(64) NULL,
    ADD COLUMN source_table VARCHAR(64) NULL,
    ADD COLUMN provenance TEXT NULL,
    ADD COLUMN status VARCHAR(32) NULL,
    ADD COLUMN error_count INT NULL,
    ADD COLUMN vector_count INT NULL;
