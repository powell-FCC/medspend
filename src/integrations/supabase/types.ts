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
      invoice_processing_jobs: {
        Row: { id: string; organization_id: string; invoice_id: string; status: string; extraction_result: Json | null; extraction_error: string | null; ocr_provider: string | null; extraction_provider: string | null; document_text_status: string; raw_extracted_text: string | null; document_page_count: number | null; document_processing_duration_ms: number | null; ocr_required: boolean; created_at: string; updated_at: string }
        Insert: { id?: string; organization_id: string; invoice_id: string; status?: string; extraction_result?: Json | null; extraction_error?: string | null; ocr_provider?: string | null; extraction_provider?: string | null; document_text_status?: string; raw_extracted_text?: string | null; document_page_count?: number | null; document_processing_duration_ms?: number | null; ocr_required?: boolean; created_at?: string; updated_at?: string }
        Update: { id?: string; organization_id?: string; invoice_id?: string; status?: string; extraction_result?: Json | null; extraction_error?: string | null; ocr_provider?: string | null; extraction_provider?: string | null; document_text_status?: string; raw_extracted_text?: string | null; document_page_count?: number | null; document_processing_duration_ms?: number | null; ocr_required?: boolean; created_at?: string; updated_at?: string }
        Relationships: []
      }
      invoice_items: {
        Row: { id: string; invoice_id: string; organization_id: string; product_id: string | null; vendor_product_id: string | null; line_number: number | null; sku: string | null; description: string; manufacturer: string | null; category: string | null; quantity: number; unit_price: number | null; total_price: number | null; unit_of_measure: string | null; package_size: string | null; review_status: string; created_at: string; updated_at: string }
        Insert: { id?: string; invoice_id: string; organization_id: string; product_id?: string | null; vendor_product_id?: string | null; line_number?: number | null; sku?: string | null; description: string; manufacturer?: string | null; category?: string | null; quantity: number; unit_price?: number | null; total_price?: number | null; unit_of_measure?: string | null; package_size?: string | null; review_status?: string; created_at?: string; updated_at?: string }
        Update: { id?: string; invoice_id?: string; organization_id?: string; product_id?: string | null; vendor_product_id?: string | null; line_number?: number | null; sku?: string | null; description?: string; manufacturer?: string | null; category?: string | null; quantity?: number; unit_price?: number | null; total_price?: number | null; unit_of_measure?: string | null; package_size?: string | null; review_status?: string; created_at?: string; updated_at?: string }
        Relationships: []
      }
      inventory_items: {
        Row: { id: string; organization_id: string; product_id: string | null; sku: string | null; name: string; description: string | null; category: string | null; manufacturer: string | null; unit: string; quantity: number; par_level: number | null; last_purchase_price: number | null; last_purchase_date: string | null; vendor_name: string | null; active: boolean; created_at: string; updated_at: string }
        Insert: { id?: string; organization_id: string; product_id?: string | null; sku?: string | null; name: string; description?: string | null; category?: string | null; manufacturer?: string | null; unit: string; quantity?: number; par_level?: number | null; last_purchase_price?: number | null; last_purchase_date?: string | null; vendor_name?: string | null; active?: boolean; created_at?: string; updated_at?: string }
        Update: { id?: string; organization_id?: string; product_id?: string | null; sku?: string | null; name?: string; description?: string | null; category?: string | null; manufacturer?: string | null; unit?: string; quantity?: number; par_level?: number | null; last_purchase_price?: number | null; last_purchase_date?: string | null; vendor_name?: string | null; active?: boolean; created_at?: string; updated_at?: string }
        Relationships: []
      }
      inventory_categories: {
        Row: { id: string; organization_id: string; name: string; created_at: string }
        Insert: { id?: string; organization_id: string; name: string; created_at?: string }
        Update: { id?: string; organization_id?: string; name?: string; created_at?: string }
        Relationships: []
      }
      inventory_adjustments: {
        Row: { id: string; organization_id: string; inventory_item_id: string; adjustment_amount: number; previous_quantity: number; new_quantity: number; reason: string; created_by: string; source_type: string | null; source_invoice_id: string | null; source_invoice_item_id: string | null; idempotency_key: string | null; created_at: string }
        Insert: { id?: string; organization_id: string; inventory_item_id: string; adjustment_amount: number; previous_quantity: number; new_quantity: number; reason: string; created_by: string; source_type?: string | null; source_invoice_id?: string | null; source_invoice_item_id?: string | null; idempotency_key?: string | null; created_at?: string }
        Update: { id?: string; organization_id?: string; inventory_item_id?: string; adjustment_amount?: number; previous_quantity?: number; new_quantity?: number; reason?: string; created_by?: string; source_type?: string | null; source_invoice_id?: string | null; source_invoice_item_id?: string | null; idempotency_key?: string | null; created_at?: string }
        Relationships: []
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
      invoices: {
        Row: {
          created_at: string
          id: string
          invoice_date: string | null
          invoice_number: string | null
          invoice_total: number | null
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
          vendor_name: string | null
          currency_code: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
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
          vendor_name?: string | null
          currency_code?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          invoice_date?: string | null
          invoice_number?: string | null
          invoice_total?: number | null
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
          vendor_name?: string | null
          currency_code?: string | null
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
          organization_id: string
          product_id: string
        }
        Insert: {
          alias: string
          created_at?: string
          id?: string
          organization_id: string
          product_id: string
        }
        Update: {
          alias?: string
          created_at?: string
          id?: string
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
        ]
      }
      products: {
        Row: {
          approved: boolean
          active: boolean
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
          approved?: boolean
          active?: boolean
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
          approved?: boolean
          active?: boolean
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
            foreignKeyName: "products_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
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
        Relationships: []
      }
      vendors: {
        Row: {
          account_number: string | null
          active: boolean
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
      adjust_inventory_quantity: {
        Args: { _organization_id: string; _inventory_item_id: string; _adjustment_amount: number; _reason: string }
        Returns: number
      }
      accept_invitation: {
        Args: { _raw_token: string }
        Returns: {
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          route: string
        }[]
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
      confirm_invoice_item_product: {
        Args: { _organization_id: string; _source_file_id: string; _invoice_item_id: string; _product_id: string; _remember_vendor_sku?: boolean }
        Returns: Json
      }
      create_product_from_invoice_item: {
        Args: { _organization_id: string; _source_file_id: string; _invoice_item_id: string }
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
      post_reviewed_invoice: {
        Args: { _organization_id: string; _source_file_id: string }
        Returns: Json
      }
      seed_structured_invoice_draft: {
        Args: { _organization_id: string; _source_file_id: string; _extraction: Json; _provider: string }
        Returns: boolean
      }
      unlink_invoice_item_product: {
        Args: { _organization_id: string; _source_file_id: string; _invoice_item_id: string; _forget_mapping?: boolean }
        Returns: undefined
      }
      receive_invoice_inventory_item: {
        Args: { _organization_id: string; _sku: string; _name: string; _vendor_name: string; _quantity: number; _unit: string; _category: string; _unit_price: number }
        Returns: { inventory_item_id: string; created: boolean }[]
      }
      revoke_invitation: { Args: { _id: string }; Returns: undefined }
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
