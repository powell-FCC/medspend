export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      catalog_categories: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
          normalized_name: string
          parent_category_id: string | null
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
          normalized_name: string
          parent_category_id?: string | null
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
          normalized_name?: string
          parent_category_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "catalog_categories_parent_category_id_fkey"
            columns: ["parent_category_id"]
            isOneToOne: false
            referencedRelation: "catalog_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      catalog_import_batches: {
        Row: {
          artifact_name: string | null
          artifact_sha256: string | null
          catalog_vendor_id: string
          completed_at: string | null
          created_at: string
          error_count: number
          id: string
          matched_record_count: number
          metadata: Json
          raw_record_count: number
          source_name: string
          source_uri: string | null
          source_version: string
          started_at: string | null
          status: string
          unique_key_count: number
          unmatched_record_count: number
          updated_at: string
          warning_count: number
        }
        Insert: {
          artifact_name?: string | null
          artifact_sha256?: string | null
          catalog_vendor_id: string
          completed_at?: string | null
          created_at?: string
          error_count?: number
          id?: string
          matched_record_count?: number
          metadata?: Json
          raw_record_count?: number
          source_name: string
          source_uri?: string | null
          source_version: string
          started_at?: string | null
          status?: string
          unique_key_count?: number
          unmatched_record_count?: number
          updated_at?: string
          warning_count?: number
        }
        Update: {
          artifact_name?: string | null
          artifact_sha256?: string | null
          catalog_vendor_id?: string
          completed_at?: string | null
          created_at?: string
          error_count?: number
          id?: string
          matched_record_count?: number
          metadata?: Json
          raw_record_count?: number
          source_name?: string
          source_uri?: string | null
          source_version?: string
          started_at?: string | null
          status?: string
          unique_key_count?: number
          unmatched_record_count?: number
          updated_at?: string
          warning_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "catalog_import_batches_catalog_vendor_id_fkey"
            columns: ["catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      catalog_products: {
        Row: {
          active: boolean
          catalog_category_id: string | null
          created_at: string
          description: string | null
          id: string
          manufacturer: string | null
          name: string
          normalized_manufacturer: string | null
          normalized_name: string
          updated_at: string
          verification_status: string
        }
        Insert: {
          active?: boolean
          catalog_category_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          manufacturer?: string | null
          name: string
          normalized_manufacturer?: string | null
          normalized_name: string
          updated_at?: string
          verification_status?: string
        }
        Update: {
          active?: boolean
          catalog_category_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          manufacturer?: string | null
          name?: string
          normalized_manufacturer?: string | null
          normalized_name?: string
          updated_at?: string
          verification_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "catalog_products_catalog_category_id_fkey"
            columns: ["catalog_category_id"]
            isOneToOne: false
            referencedRelation: "catalog_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      catalog_source_records: {
        Row: {
          catalog_vendor_id: string
          created_at: string
          id: string
          import_batch_id: string
          matched_catalog_vendor_product_id: string | null
          normalized_raw_vendor_sku: string | null
          raw_category: string | null
          raw_data: Json
          raw_package: string | null
          raw_product_name: string | null
          raw_subsection: string | null
          raw_variant: string | null
          raw_vendor_sku: string | null
          raw_vendor_sku_match_key: string | null
          resolution_status: string
          resolved_at: string | null
          source_ordinal: number
          source_page: string | null
          updated_at: string
        }
        Insert: {
          catalog_vendor_id: string
          created_at?: string
          id?: string
          import_batch_id: string
          matched_catalog_vendor_product_id?: string | null
          normalized_raw_vendor_sku?: string | null
          raw_category?: string | null
          raw_data: Json
          raw_package?: string | null
          raw_product_name?: string | null
          raw_subsection?: string | null
          raw_variant?: string | null
          raw_vendor_sku?: string | null
          raw_vendor_sku_match_key?: string | null
          resolution_status?: string
          resolved_at?: string | null
          source_ordinal: number
          source_page?: string | null
          updated_at?: string
        }
        Update: {
          catalog_vendor_id?: string
          created_at?: string
          id?: string
          import_batch_id?: string
          matched_catalog_vendor_product_id?: string | null
          normalized_raw_vendor_sku?: string | null
          raw_category?: string | null
          raw_data?: Json
          raw_package?: string | null
          raw_product_name?: string | null
          raw_subsection?: string | null
          raw_variant?: string | null
          raw_vendor_sku?: string | null
          raw_vendor_sku_match_key?: string | null
          resolution_status?: string
          resolved_at?: string | null
          source_ordinal?: number
          source_page?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "catalog_source_records_batch_vendor_fk"
            columns: ["import_batch_id", "catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_import_batches"
            referencedColumns: ["id", "catalog_vendor_id"]
          },
          {
            foreignKeyName: "catalog_source_records_match_vendor_fk"
            columns: ["matched_catalog_vendor_product_id", "catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendor_products"
            referencedColumns: ["id", "catalog_vendor_id"]
          },
        ]
      }
      catalog_vendor_products: {
        Row: {
          active: boolean
          catalog_product_id: string
          catalog_vendor_id: string
          created_at: string
          currency_code: string | null
          discontinued: boolean
          id: string
          manufacturer_sku: string | null
          normalized_manufacturer_sku: string | null
          normalized_vendor_sku: string
          package_description: string | null
          package_quantity: number | null
          package_status: string
          package_unit: string | null
          source_catalog_price: number | null
          updated_at: string
          vendor_sku: string
          vendor_sku_match_key: string | null
          verification_status: string
        }
        Insert: {
          active?: boolean
          catalog_product_id: string
          catalog_vendor_id: string
          created_at?: string
          currency_code?: string | null
          discontinued?: boolean
          id?: string
          manufacturer_sku?: string | null
          normalized_manufacturer_sku?: string | null
          normalized_vendor_sku: string
          package_description?: string | null
          package_quantity?: number | null
          package_status?: string
          package_unit?: string | null
          source_catalog_price?: number | null
          updated_at?: string
          vendor_sku: string
          vendor_sku_match_key?: string | null
          verification_status?: string
        }
        Update: {
          active?: boolean
          catalog_product_id?: string
          catalog_vendor_id?: string
          created_at?: string
          currency_code?: string | null
          discontinued?: boolean
          id?: string
          manufacturer_sku?: string | null
          normalized_manufacturer_sku?: string | null
          normalized_vendor_sku?: string
          package_description?: string | null
          package_quantity?: number | null
          package_status?: string
          package_unit?: string | null
          source_catalog_price?: number | null
          updated_at?: string
          vendor_sku?: string
          vendor_sku_match_key?: string | null
          verification_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "catalog_vendor_products_catalog_product_id_fkey"
            columns: ["catalog_product_id"]
            isOneToOne: false
            referencedRelation: "catalog_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "catalog_vendor_products_catalog_vendor_id_fkey"
            columns: ["catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      catalog_vendors: {
        Row: {
          active: boolean
          created_at: string
          domain: string | null
          id: string
          name: string
          normalized_name: string
          updated_at: string
          website: string | null
        }
        Insert: {
          active?: boolean
          created_at?: string
          domain?: string | null
          id?: string
          name: string
          normalized_name: string
          updated_at?: string
          website?: string | null
        }
        Update: {
          active?: boolean
          created_at?: string
          domain?: string | null
          id?: string
          name?: string
          normalized_name?: string
          updated_at?: string
          website?: string | null
        }
        Relationships: []
      }
      catalog_verification_overrides: {
        Row: {
          active: boolean
          catalog_vendor_id: string
          catalog_vendor_product_id: string | null
          created_at: string
          created_by: string | null
          effective_from: string
          effective_to: string | null
          evidence: Json
          evidence_status: string
          id: string
          import_batch_id: string | null
          normalized_source_vendor_sku: string | null
          normalized_verified_vendor_sku: string | null
          notes: string | null
          override_type: string
          production_rule: string
          source_record_id: string | null
          source_vendor_sku: string | null
          updated_at: string
          verified_vendor_sku: string | null
        }
        Insert: {
          active?: boolean
          catalog_vendor_id: string
          catalog_vendor_product_id?: string | null
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          evidence?: Json
          evidence_status?: string
          id?: string
          import_batch_id?: string | null
          normalized_source_vendor_sku?: string | null
          normalized_verified_vendor_sku?: string | null
          notes?: string | null
          override_type: string
          production_rule: string
          source_record_id?: string | null
          source_vendor_sku?: string | null
          updated_at?: string
          verified_vendor_sku?: string | null
        }
        Update: {
          active?: boolean
          catalog_vendor_id?: string
          catalog_vendor_product_id?: string | null
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          evidence?: Json
          evidence_status?: string
          id?: string
          import_batch_id?: string | null
          normalized_source_vendor_sku?: string | null
          normalized_verified_vendor_sku?: string | null
          notes?: string | null
          override_type?: string
          production_rule?: string
          source_record_id?: string | null
          source_vendor_sku?: string | null
          updated_at?: string
          verified_vendor_sku?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "catalog_verification_overrides_batch_vendor_fk"
            columns: ["import_batch_id", "catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_import_batches"
            referencedColumns: ["id", "catalog_vendor_id"]
          },
          {
            foreignKeyName: "catalog_verification_overrides_catalog_vendor_id_fkey"
            columns: ["catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "catalog_verification_overrides_product_vendor_fk"
            columns: ["catalog_vendor_product_id", "catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendor_products"
            referencedColumns: ["id", "catalog_vendor_id"]
          },
          {
            foreignKeyName: "catalog_verification_overrides_source_vendor_fk"
            columns: ["source_record_id", "catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_source_records"
            referencedColumns: ["id", "catalog_vendor_id"]
          },
        ]
      }
      inventory_adjustments: {
        Row: {
          adjustment_amount: number
          created_at: string
          created_by: string
          id: string
          idempotency_key: string | null
          inventory_item_id: string
          new_quantity: number
          organization_id: string
          previous_quantity: number
          reason: string
          source_invoice_id: string | null
          source_invoice_item_id: string | null
          source_type: string | null
        }
        Insert: {
          adjustment_amount: number
          created_at?: string
          created_by: string
          id?: string
          idempotency_key?: string | null
          inventory_item_id: string
          new_quantity: number
          organization_id: string
          previous_quantity: number
          reason: string
          source_invoice_id?: string | null
          source_invoice_item_id?: string | null
          source_type?: string | null
        }
        Update: {
          adjustment_amount?: number
          created_at?: string
          created_by?: string
          id?: string
          idempotency_key?: string | null
          inventory_item_id?: string
          new_quantity?: number
          organization_id?: string
          previous_quantity?: number
          reason?: string
          source_invoice_id?: string | null
          source_invoice_item_id?: string | null
          source_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_adjustments_inventory_item_id_fkey"
            columns: ["inventory_item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_adjustments_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_adjustments_source_invoice_org_fk"
            columns: ["source_invoice_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "inventory_adjustments_source_item_org_fk"
            columns: ["source_invoice_item_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoice_items"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      inventory_categories: {
        Row: {
          created_at: string
          id: string
          name: string
          organization_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          organization_id: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "inventory_categories_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      inventory_items: {
        Row: {
          active: boolean
          category: string | null
          created_at: string
          description: string | null
          id: string
          last_purchase_date: string | null
          last_purchase_price: number | null
          manufacturer: string | null
          name: string
          organization_id: string
          par_level: number | null
          product_id: string | null
          quantity: number
          sku: string | null
          unit: string
          updated_at: string
          vendor_name: string | null
        }
        Insert: {
          active?: boolean
          category?: string | null
          created_at?: string
          description?: string | null
          id?: string
          last_purchase_date?: string | null
          last_purchase_price?: number | null
          manufacturer?: string | null
          name: string
          organization_id: string
          par_level?: number | null
          product_id?: string | null
          quantity?: number
          sku?: string | null
          unit: string
          updated_at?: string
          vendor_name?: string | null
        }
        Update: {
          active?: boolean
          category?: string | null
          created_at?: string
          description?: string | null
          id?: string
          last_purchase_date?: string | null
          last_purchase_price?: number | null
          manufacturer?: string | null
          name?: string
          organization_id?: string
          par_level?: number | null
          product_id?: string | null
          quantity?: number
          sku?: string | null
          unit?: string
          updated_at?: string
          vendor_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_items_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      inventory_price_history: {
        Row: {
          created_at: string
          extended_price: number | null
          id: string
          invoice_id: string
          invoice_item_id: string
          organization_id: string
          package_size: string | null
          product_id: string
          purchase_date: string
          quantity: number
          unit_of_measure: string | null
          unit_price: number | null
          vendor_id: string
          vendor_product_id: string | null
        }
        Insert: {
          created_at?: string
          extended_price?: number | null
          id?: string
          invoice_id: string
          invoice_item_id: string
          organization_id: string
          package_size?: string | null
          product_id: string
          purchase_date: string
          quantity: number
          unit_of_measure?: string | null
          unit_price?: number | null
          vendor_id: string
          vendor_product_id?: string | null
        }
        Update: {
          created_at?: string
          extended_price?: number | null
          id?: string
          invoice_id?: string
          invoice_item_id?: string
          organization_id?: string
          package_size?: string | null
          product_id?: string
          purchase_date?: string
          quantity?: number
          unit_of_measure?: string | null
          unit_price?: number | null
          vendor_id?: string
          vendor_product_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_price_history_invoice_item_org_fk"
            columns: ["invoice_item_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoice_items"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "inventory_price_history_invoice_org_fk"
            columns: ["invoice_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "inventory_price_history_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_price_history_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "inventory_price_history_vendor_org_fk"
            columns: ["vendor_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "inventory_price_history_vendor_product_org_fk"
            columns: ["vendor_product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendor_products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      invoice_extraction_candidates: {
        Row: {
          candidate_type: string
          confidence_data: Json
          created_at: string
          extraction_run_id: string
          field_data: Json
          id: string
          line_number: number | null
          organization_id: string
          review_status: string
          source_data: Json
          updated_at: string
        }
        Insert: {
          candidate_type: string
          confidence_data?: Json
          created_at?: string
          extraction_run_id: string
          field_data?: Json
          id?: string
          line_number?: number | null
          organization_id: string
          review_status?: string
          source_data?: Json
          updated_at?: string
        }
        Update: {
          candidate_type?: string
          confidence_data?: Json
          created_at?: string
          extraction_run_id?: string
          field_data?: Json
          id?: string
          line_number?: number | null
          organization_id?: string
          review_status?: string
          source_data?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoice_extraction_candidates_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_extraction_candidates_run_org_fk"
            columns: ["extraction_run_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoice_extraction_runs"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      invoice_extraction_runs: {
        Row: {
          attempt_number: number
          completed_at: string | null
          created_at: string
          error_code: string | null
          error_message: string | null
          extractor_name: string | null
          extractor_version: string | null
          id: string
          organization_id: string
          processing_job_id: string
          raw_result: Json | null
          schema_version: string
          started_at: string | null
          status: string
          updated_at: string
          vendor_invoice_id: string
        }
        Insert: {
          attempt_number?: number
          completed_at?: string | null
          created_at?: string
          error_code?: string | null
          error_message?: string | null
          extractor_name?: string | null
          extractor_version?: string | null
          id?: string
          organization_id: string
          processing_job_id: string
          raw_result?: Json | null
          schema_version?: string
          started_at?: string | null
          status?: string
          updated_at?: string
          vendor_invoice_id: string
        }
        Update: {
          attempt_number?: number
          completed_at?: string | null
          created_at?: string
          error_code?: string | null
          error_message?: string | null
          extractor_name?: string | null
          extractor_version?: string | null
          id?: string
          organization_id?: string
          processing_job_id?: string
          raw_result?: Json | null
          schema_version?: string
          started_at?: string | null
          status?: string
          updated_at?: string
          vendor_invoice_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoice_extraction_runs_job_org_fk"
            columns: ["processing_job_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "invoice_processing_jobs"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "invoice_extraction_runs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_extraction_runs_source_org_fk"
            columns: ["vendor_invoice_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendor_invoices"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      invoice_items: {
        Row: {
          category: string | null
          created_at: string
          description: string
          id: string
          invoice_id: string
          line_number: number | null
          manufacturer: string | null
          organization_id: string
          package_size: string | null
          product_id: string | null
          quantity: number
          review_status: string
          sku: string | null
          total_price: number | null
          unit_of_measure: string | null
          unit_price: number | null
          updated_at: string
          vendor_product_id: string | null
        }
        Insert: {
          category?: string | null
          created_at?: string
          description: string
          id?: string
          invoice_id: string
          line_number?: number | null
          manufacturer?: string | null
          organization_id: string
          package_size?: string | null
          product_id?: string | null
          quantity: number
          review_status?: string
          sku?: string | null
          total_price?: number | null
          unit_of_measure?: string | null
          unit_price?: number | null
          updated_at?: string
          vendor_product_id?: string | null
        }
        Update: {
          category?: string | null
          created_at?: string
          description?: string
          id?: string
          invoice_id?: string
          line_number?: number | null
          manufacturer?: string | null
          organization_id?: string
          package_size?: string | null
          product_id?: string | null
          quantity?: number
          review_status?: string
          sku?: string | null
          total_price?: number | null
          unit_of_measure?: string | null
          unit_price?: number | null
          updated_at?: string
          vendor_product_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoice_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "invoice_items_vendor_product_org_fk"
            columns: ["vendor_product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendor_products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      invoice_line_items: {
        Row: {
          created_at: string
          description: string | null
          id: string
          invoice_id: string
          line_total: number | null
          organization_id: string
          product_id: string | null
          quantity: number | null
          unit_price: number | null
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          invoice_id: string
          line_total?: number | null
          organization_id: string
          product_id?: string | null
          quantity?: number | null
          unit_price?: number | null
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          invoice_id?: string
          line_total?: number | null
          organization_id?: string
          product_id?: string | null
          quantity?: number | null
          unit_price?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoice_line_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_line_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_line_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_processing_jobs: {
        Row: {
          created_at: string
          document_page_count: number | null
          document_processing_duration_ms: number | null
          document_text_status: string
          extraction_error: string | null
          extraction_provider: string | null
          extraction_result: Json | null
          id: string
          invoice_id: string
          ocr_provider: string | null
          ocr_required: boolean
          organization_id: string
          raw_extracted_text: string | null
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          document_page_count?: number | null
          document_processing_duration_ms?: number | null
          document_text_status?: string
          extraction_error?: string | null
          extraction_provider?: string | null
          extraction_result?: Json | null
          id?: string
          invoice_id: string
          ocr_provider?: string | null
          ocr_required?: boolean
          organization_id: string
          raw_extracted_text?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          document_page_count?: number | null
          document_processing_duration_ms?: number | null
          document_text_status?: string
          extraction_error?: string | null
          extraction_provider?: string | null
          extraction_result?: Json | null
          id?: string
          invoice_id?: string
          ocr_provider?: string | null
          ocr_required?: boolean
          organization_id?: string
          raw_extracted_text?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoice_processing_jobs_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: true
            referencedRelation: "vendor_invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_processing_jobs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          created_at: string
          currency_code: string | null
          document_type: string
          id: string
          invoice_date: string | null
          invoice_number: string | null
          invoice_total: number | null
          order_date: string | null
          order_number: string | null
          organization_id: string
          payment_terms: string | null
          posted_at: string | null
          processing_status: string
          purchase_order_number: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          shipping_amount: number | null
          source_file_id: string | null
          subtotal: number | null
          tax_amount: number | null
          total: number | null
          total_amount: number | null
          updated_at: string
          vendor_id: string | null
          vendor_identity_reviewed: boolean
          vendor_name: string | null
        }
        Insert: {
          created_at?: string
          currency_code?: string | null
          document_type?: string
          id?: string
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
          order_date?: string | null
          order_number?: string | null
          organization_id: string
          payment_terms?: string | null
          posted_at?: string | null
          processing_status?: string
          purchase_order_number?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          shipping_amount?: number | null
          source_file_id?: string | null
          subtotal?: number | null
          tax_amount?: number | null
          total?: number | null
          total_amount?: number | null
          updated_at?: string
          vendor_id?: string | null
          vendor_identity_reviewed?: boolean
          vendor_name?: string | null
        }
        Update: {
          created_at?: string
          currency_code?: string | null
          document_type?: string
          id?: string
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
          order_date?: string | null
          order_number?: string | null
          organization_id?: string
          payment_terms?: string | null
          posted_at?: string | null
          processing_status?: string
          purchase_order_number?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          shipping_amount?: number | null
          source_file_id?: string | null
          subtotal?: number | null
          tax_amount?: number | null
          total?: number | null
          total_amount?: number | null
          updated_at?: string
          vendor_id?: string | null
          vendor_identity_reviewed?: boolean
          vendor_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_source_file_id_fkey"
            columns: ["source_file_id"]
            isOneToOne: true
            referencedRelation: "vendor_invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      locations: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "locations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_invites: {
        Row: {
          accepted_at: string | null
          created_at: string
          default_location_id: string | null
          default_team_id: string | null
          expires_at: string
          id: string
          invited_by: string | null
          invited_email: string
          invited_name: string | null
          invited_role: Database["public"]["Enums"]["org_role"]
          organization_id: string
          revoked_at: string | null
          token_hash: string
        }
        Insert: {
          accepted_at?: string | null
          created_at?: string
          default_location_id?: string | null
          default_team_id?: string | null
          expires_at: string
          id?: string
          invited_by?: string | null
          invited_email: string
          invited_name?: string | null
          invited_role?: Database["public"]["Enums"]["org_role"]
          organization_id: string
          revoked_at?: string | null
          token_hash: string
        }
        Update: {
          accepted_at?: string | null
          created_at?: string
          default_location_id?: string | null
          default_team_id?: string | null
          expires_at?: string
          id?: string
          invited_by?: string | null
          invited_email?: string
          invited_name?: string | null
          invited_role?: Database["public"]["Enums"]["org_role"]
          organization_id?: string
          revoked_at?: string | null
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_invites_default_location_id_fkey"
            columns: ["default_location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_invites_default_team_id_fkey"
            columns: ["default_team_id"]
            isOneToOne: false
            referencedRelation: "teams"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_invites_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_memberships: {
        Row: {
          active: boolean
          created_at: string
          default_location_id: string | null
          default_team_id: string | null
          id: string
          invited_by: string | null
          joined_at: string
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          updated_at: string
          user_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          default_location_id?: string | null
          default_team_id?: string | null
          id?: string
          invited_by?: string | null
          joined_at?: string
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          updated_at?: string
          user_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          default_location_id?: string | null
          default_team_id?: string | null
          id?: string
          invited_by?: string | null
          joined_at?: string
          organization_id?: string
          role?: Database["public"]["Enums"]["org_role"]
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "om_default_location_fk"
            columns: ["default_location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "om_default_team_fk"
            columns: ["default_team_id"]
            isOneToOne: false
            referencedRelation: "teams"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_memberships_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      product_aliases: {
        Row: {
          alias: string
          created_at: string
          id: string
          normalized_alias: string
          organization_id: string
          product_id: string
        }
        Insert: {
          alias: string
          created_at?: string
          id?: string
          normalized_alias: string
          organization_id: string
          product_id: string
        }
        Update: {
          alias?: string
          created_at?: string
          id?: string
          normalized_alias?: string
          organization_id?: string
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_aliases_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_aliases_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_aliases_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      product_categories: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
          normalized_name: string
          organization_id: string
          parent_category_id: string | null
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
          normalized_name: string
          organization_id: string
          parent_category_id?: string | null
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
          normalized_name?: string
          organization_id?: string
          parent_category_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_categories_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_categories_parent_category_id_fkey"
            columns: ["parent_category_id"]
            isOneToOne: false
            referencedRelation: "product_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_categories_parent_org_fk"
            columns: ["parent_category_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "product_categories"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      products: {
        Row: {
          active: boolean
          approved: boolean
          catalog_product_id: string | null
          category_id: string | null
          created_at: string
          description: string | null
          id: string
          internal_item_code: string | null
          manufacturer: string | null
          name: string
          normalized_name: string
          organization_id: string
          pack_size: string | null
          preferred_vendor_id: string | null
          staff_requestable: boolean
          unit: string | null
          unit_of_measure: string | null
          updated_at: string
          vendor_item_number: string | null
        }
        Insert: {
          active?: boolean
          approved?: boolean
          catalog_product_id?: string | null
          category_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          internal_item_code?: string | null
          manufacturer?: string | null
          name: string
          normalized_name: string
          organization_id: string
          pack_size?: string | null
          preferred_vendor_id?: string | null
          staff_requestable?: boolean
          unit?: string | null
          unit_of_measure?: string | null
          updated_at?: string
          vendor_item_number?: string | null
        }
        Update: {
          active?: boolean
          approved?: boolean
          catalog_product_id?: string | null
          category_id?: string | null
          created_at?: string
          description?: string | null
          id?: string
          internal_item_code?: string | null
          manufacturer?: string | null
          name?: string
          normalized_name?: string
          organization_id?: string
          pack_size?: string | null
          preferred_vendor_id?: string | null
          staff_requestable?: boolean
          unit?: string | null
          unit_of_measure?: string | null
          updated_at?: string
          vendor_item_number?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "products_catalog_product_fk"
            columns: ["catalog_product_id"]
            isOneToOne: false
            referencedRelation: "catalog_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "product_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_category_org_fk"
            columns: ["category_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "product_categories"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "products_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_preferred_vendor_id_fkey"
            columns: ["preferred_vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_vendor_org_fk"
            columns: ["preferred_vendor_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string
          email: string | null
          full_name: string | null
          id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          email?: string | null
          full_name?: string | null
          id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          email?: string | null
          full_name?: string | null
          id?: string
          updated_at?: string
        }
        Relationships: []
      }
      supply_request_items: {
        Row: {
          created_at: string
          free_text_item: string | null
          id: string
          organization_id: string
          product_id: string | null
          quantity: number
          supply_request_id: string
          unit: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          free_text_item?: string | null
          id?: string
          organization_id: string
          product_id?: string | null
          quantity: number
          supply_request_id: string
          unit?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          free_text_item?: string | null
          id?: string
          organization_id?: string
          product_id?: string | null
          quantity?: number
          supply_request_id?: string
          unit?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "supply_request_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_request_items_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "supply_request_items_request_org_fk"
            columns: ["supply_request_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "supply_requests"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      supply_request_updates: {
        Row: {
          author_id: string | null
          created_at: string
          id: string
          internal_note: string | null
          organization_id: string
          staff_visible_note: string | null
          status_from:
            | Database["public"]["Enums"]["supply_request_status"]
            | null
          status_to: Database["public"]["Enums"]["supply_request_status"] | null
          supply_request_id: string
        }
        Insert: {
          author_id?: string | null
          created_at?: string
          id?: string
          internal_note?: string | null
          organization_id: string
          staff_visible_note?: string | null
          status_from?:
            | Database["public"]["Enums"]["supply_request_status"]
            | null
          status_to?:
            | Database["public"]["Enums"]["supply_request_status"]
            | null
          supply_request_id: string
        }
        Update: {
          author_id?: string | null
          created_at?: string
          id?: string
          internal_note?: string | null
          organization_id?: string
          staff_visible_note?: string | null
          status_from?:
            | Database["public"]["Enums"]["supply_request_status"]
            | null
          status_to?:
            | Database["public"]["Enums"]["supply_request_status"]
            | null
          supply_request_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "supply_request_updates_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_request_updates_supply_request_id_fkey"
            columns: ["supply_request_id"]
            isOneToOne: false
            referencedRelation: "supply_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      supply_requests: {
        Row: {
          assigned_to: string | null
          created_at: string
          free_text_item: string | null
          id: string
          location_id: string | null
          notes: string | null
          ordered_at: string | null
          organization_id: string
          product_id: string | null
          quantity: number | null
          received_at: string | null
          request_type: Database["public"]["Enums"]["supply_request_type"]
          requested_by: string
          status: Database["public"]["Enums"]["supply_request_status"]
          team_id: string | null
          updated_at: string
          vendor_id: string | null
        }
        Insert: {
          assigned_to?: string | null
          created_at?: string
          free_text_item?: string | null
          id?: string
          location_id?: string | null
          notes?: string | null
          ordered_at?: string | null
          organization_id: string
          product_id?: string | null
          quantity?: number | null
          received_at?: string | null
          request_type: Database["public"]["Enums"]["supply_request_type"]
          requested_by: string
          status?: Database["public"]["Enums"]["supply_request_status"]
          team_id?: string | null
          updated_at?: string
          vendor_id?: string | null
        }
        Update: {
          assigned_to?: string | null
          created_at?: string
          free_text_item?: string | null
          id?: string
          location_id?: string | null
          notes?: string | null
          ordered_at?: string | null
          organization_id?: string
          product_id?: string | null
          quantity?: number | null
          received_at?: string | null
          request_type?: Database["public"]["Enums"]["supply_request_type"]
          requested_by?: string
          status?: Database["public"]["Enums"]["supply_request_status"]
          team_id?: string | null
          updated_at?: string
          vendor_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supply_requests_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_requests_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_requests_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_requests_team_id_fkey"
            columns: ["team_id"]
            isOneToOne: false
            referencedRelation: "teams"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supply_requests_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      teams: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "teams_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_identity_signatures: {
        Row: {
          active: boolean
          created_at: string
          id: string
          normalized_value: string
          organization_id: string
          signature_type: string
          updated_at: string
          vendor_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          normalized_value: string
          organization_id: string
          signature_type: string
          updated_at?: string
          vendor_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          normalized_value?: string
          organization_id?: string
          signature_type?: string
          updated_at?: string
          vendor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_identity_signatures_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_identity_signatures_vendor_org_fk"
            columns: ["vendor_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      vendor_invoices: {
        Row: {
          created_at: string
          file_size: number
          id: string
          mime_type: string
          organization_id: string
          original_filename: string
          status: string
          storage_path: string
          uploaded_by: string
        }
        Insert: {
          created_at?: string
          file_size: number
          id?: string
          mime_type: string
          organization_id: string
          original_filename: string
          status?: string
          storage_path: string
          uploaded_by: string
        }
        Update: {
          created_at?: string
          file_size?: number
          id?: string
          mime_type?: string
          organization_id?: string
          original_filename?: string
          status?: string
          storage_path?: string
          uploaded_by?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_invoices_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_products: {
        Row: {
          active: boolean
          catalog_vendor_product_id: string | null
          created_at: string
          id: string
          manufacturer_sku: string | null
          organization_id: string
          package_size: string | null
          product_id: string
          unit_of_measure: string | null
          updated_at: string
          vendor_id: string
          vendor_sku: string
        }
        Insert: {
          active?: boolean
          catalog_vendor_product_id?: string | null
          created_at?: string
          id?: string
          manufacturer_sku?: string | null
          organization_id: string
          package_size?: string | null
          product_id: string
          unit_of_measure?: string | null
          updated_at?: string
          vendor_id: string
          vendor_sku: string
        }
        Update: {
          active?: boolean
          catalog_vendor_product_id?: string | null
          created_at?: string
          id?: string
          manufacturer_sku?: string | null
          organization_id?: string
          package_size?: string | null
          product_id?: string
          unit_of_measure?: string | null
          updated_at?: string
          vendor_id?: string
          vendor_sku?: string
        }
        Relationships: [
          {
            foreignKeyName: "vendor_products_catalog_vendor_product_fk"
            columns: ["catalog_vendor_product_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendor_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_products_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendor_products_product_org_fk"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "vendor_products_vendor_org_fk"
            columns: ["vendor_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "vendors"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      vendors: {
        Row: {
          account_number: string | null
          active: boolean
          catalog_vendor_id: string | null
          contact_name: string | null
          created_at: string
          email: string | null
          id: string
          name: string
          normalized_name: string
          notes: string | null
          organization_id: string
          phone: string | null
          updated_at: string
          website: string | null
        }
        Insert: {
          account_number?: string | null
          active?: boolean
          catalog_vendor_id?: string | null
          contact_name?: string | null
          created_at?: string
          email?: string | null
          id?: string
          name: string
          normalized_name: string
          notes?: string | null
          organization_id: string
          phone?: string | null
          updated_at?: string
          website?: string | null
        }
        Update: {
          account_number?: string | null
          active?: boolean
          catalog_vendor_id?: string | null
          contact_name?: string | null
          created_at?: string
          email?: string | null
          id?: string
          name?: string
          normalized_name?: string
          notes?: string | null
          organization_id?: string
          phone?: string | null
          updated_at?: string
          website?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vendors_catalog_vendor_fk"
            columns: ["catalog_vendor_id"]
            isOneToOne: false
            referencedRelation: "catalog_vendors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vendors_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_invitation: {
        Args: { _raw_token: string }
        Returns: {
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          route: string
        }[]
      }
      adjust_inventory_quantity: {
        Args: {
          _adjustment_amount: number
          _inventory_item_id: string
          _organization_id: string
          _reason: string
        }
        Returns: number
      }
      adopt_catalog_vendor_product: {
        Args: { _catalog_vendor_product_id: string; _organization_id: string }
        Returns: Json
      }
      confirm_invoice_item_product: {
        Args: {
          _invoice_item_id: string
          _organization_id: string
          _product_id: string
          _remember_vendor_sku?: boolean
          _source_file_id: string
        }
        Returns: Json
      }
      create_invitation: {
        Args: {
          _default_location_id: string
          _default_team_id: string
          _invited_email: string
          _invited_name: string
          _invited_role: Database["public"]["Enums"]["org_role"]
          _organization_id: string
        }
        Returns: string
      }
      create_organization: { Args: { _name: string }; Returns: string }
      create_product_from_invoice_item: {
        Args: {
          _invoice_item_id: string
          _organization_id: string
          _source_file_id: string
        }
        Returns: Json
      }
      delete_invoice_permanently: {
        Args: { _organization_id: string; _source_file_id: string }
        Returns: Json
      }
      forget_invoice_vendor_signatures: {
        Args: { _organization_id: string; _source_file_id: string }
        Returns: number
      }
      get_catalog_vendor_product_admin_detail: {
        Args: { _catalog_vendor_product_id: string; _organization_id: string }
        Returns: Json
      }
      has_org_role: {
        Args: {
          _org: string
          _roles: Database["public"]["Enums"]["org_role"][]
          _user: string
        }
        Returns: boolean
      }
      is_org_admin: { Args: { _org: string; _user: string }; Returns: boolean }
      is_org_member: { Args: { _org: string; _user: string }; Returns: boolean }
      list_organization_member_identities: {
        Args: { _organization_id: string }
        Returns: {
          default_location_name: string
          default_team_name: string
          display_name: string
          email: string
          user_id: string
        }[]
      }
      normalize_catalog_sku: { Args: { _value: string }; Returns: string }
      normalize_catalog_sku_match_key: {
        Args: { _value: string }
        Returns: string
      }
      normalize_catalog_text: { Args: { _value: string }; Returns: string }
      persist_invoice_document_identity: {
        Args: {
          _document_type: string
          _order_date: string
          _order_number: string
          _organization_id: string
          _source_file_id: string
        }
        Returns: undefined
      }
      post_reviewed_invoice: {
        Args: { _organization_id: string; _source_file_id: string }
        Returns: Json
      }
      receive_invoice_inventory_item: {
        Args: {
          _category: string
          _name: string
          _organization_id: string
          _quantity: number
          _sku: string
          _unit: string
          _unit_price: number
          _vendor_name: string
        }
        Returns: {
          created: boolean
          inventory_item_id: string
        }[]
      }
      rematch_invoice_vendor_products: {
        Args: { _organization_id: string; _source_file_id: string }
        Returns: number
      }
      remember_invoice_vendor_signatures: {
        Args: {
          _evidence: Json
          _organization_id: string
          _source_file_id: string
          _vendor_id: string
        }
        Returns: number
      }
      revoke_invitation: { Args: { _id: string }; Returns: undefined }
      seed_product_categories: {
        Args: { _organization_id: string }
        Returns: undefined
      }
      seed_structured_invoice_draft: {
        Args: {
          _extraction: Json
          _organization_id: string
          _provider: string
          _source_file_id: string
        }
        Returns: boolean
      }
      submit_supply_request: {
        Args: {
          _items: Json
          _location_id: string
          _notes: string
          _organization_id: string
          _request_type: Database["public"]["Enums"]["supply_request_type"]
          _team_id: string
        }
        Returns: string
      }
      transition_supply_request: {
        Args: {
          _internal_note?: string
          _organization_id: string
          _request_id: string
          _staff_visible_note?: string
          _status: Database["public"]["Enums"]["supply_request_status"]
        }
        Returns: Json
      }
      unlink_invoice_item_product: {
        Args: {
          _forget_mapping?: boolean
          _invoice_item_id: string
          _organization_id: string
          _source_file_id: string
        }
        Returns: undefined
      }
    }
    Enums: {
      org_role: "owner" | "admin" | "staff"
      supply_request_status:
        | "submitted"
        | "under_review"
        | "approved"
        | "ordered"
        | "received"
        | "completed"
        | "denied"
      supply_request_type: "reorder" | "low_stock" | "out_of_stock" | "new_item"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      org_role: ["owner", "admin", "staff"],
      supply_request_status: [
        "submitted",
        "under_review",
        "approved",
        "ordered",
        "received",
        "completed",
        "denied",
      ],
      supply_request_type: ["reorder", "low_stock", "out_of_stock", "new_item"],
    },
  },
} as const
