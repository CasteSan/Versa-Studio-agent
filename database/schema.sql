-- ============================================================
-- VERSA STUDIO AGENT - SUPABASE SCHEMA COMPLETO
-- ============================================================
-- Ejecutar este script en Supabase SQL Editor
-- Incluye tablas + funciones + función de vinculación
-- ============================================================

-- ============================================================
-- TABLA: leads
-- ============================================================
CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL,
  empresa TEXT NOT NULL,
  email TEXT NOT NULL,
  telefono TEXT,
  sector TEXT,
  tamano_empresa TEXT,
  necesidad_principal TEXT NOT NULL,
  cualificado BOOLEAN DEFAULT false,
  session_id TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_email ON leads(email);
CREATE INDEX IF NOT EXISTS idx_leads_session ON leads(session_id);
CREATE INDEX IF NOT EXISTS idx_leads_cualificado ON leads(cualificado);

-- ============================================================
-- TABLA: appointments
-- ============================================================
CREATE TABLE IF NOT EXISTS appointments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion_minutos INTEGER DEFAULT 30,
  estado TEXT DEFAULT 'confirmada' CHECK (estado IN ('confirmada', 'cancelada', 'completada', 'no_show')),
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_appointments_fecha ON appointments(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_appointments_lead ON appointments(lead_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_slot_unique 
ON appointments(fecha_hora) WHERE estado = 'confirmada';

-- ============================================================
-- TABLA: conversation_state (opcional)
-- ============================================================
CREATE TABLE IF NOT EXISTS conversation_state (
  session_id TEXT PRIMARY KEY,
  current_state TEXT DEFAULT 'SALUDO',
  collected_data JSONB DEFAULT '{}'::jsonb,
  objecion_intentada BOOLEAN DEFAULT false,
  last_interaction TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ============================================================
-- TABLA: logs (opcional, para debugging)
-- ============================================================
CREATE TABLE IF NOT EXISTS logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id TEXT,
  level TEXT DEFAULT 'info' CHECK (level IN ('debug', 'info', 'warn', 'error')),
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ============================================================
-- TRIGGER: auto-update updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS update_leads_updated_at ON leads;
CREATE TRIGGER update_leads_updated_at
  BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_appointments_updated_at ON appointments;
CREATE TRIGGER update_appointments_updated_at
  BEFORE UPDATE ON appointments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- FUNCIÓN: is_slot_available
-- Verifica si un horario está libre
-- ============================================================
CREATE OR REPLACE FUNCTION is_slot_available(p_fecha_hora TIMESTAMP WITH TIME ZONE)
RETURNS BOOLEAN AS $$
DECLARE
  v_count INTEGER;
  v_day_of_week INTEGER;
  v_hour INTEGER;
  v_minute INTEGER;
BEGIN
  v_day_of_week := EXTRACT(DOW FROM p_fecha_hora AT TIME ZONE 'Europe/Madrid');
  IF v_day_of_week IN (0, 6) THEN RETURN false; END IF;
  
  v_hour := EXTRACT(HOUR FROM p_fecha_hora AT TIME ZONE 'Europe/Madrid');
  v_minute := EXTRACT(MINUTE FROM p_fecha_hora AT TIME ZONE 'Europe/Madrid');
  
  IF NOT (
    (v_hour >= 10 AND v_hour < 13) OR 
    (v_hour = 13 AND v_minute = 0) OR
    (v_hour >= 16 AND v_hour < 17) OR
    (v_hour = 17 AND v_minute = 0)
  ) THEN RETURN false; END IF;
  
  SELECT COUNT(*) INTO v_count FROM appointments
  WHERE fecha_hora = p_fecha_hora AND estado = 'confirmada';
  
  RETURN v_count = 0;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCIÓN: get_available_slots
-- Obtiene slots disponibles para una fecha
-- ============================================================
CREATE OR REPLACE FUNCTION get_available_slots(
  p_fecha DATE,
  p_min_anticipacion_horas INTEGER DEFAULT 24
)
RETURNS TABLE(slot_time TIMESTAMP WITH TIME ZONE) AS $$
DECLARE
  v_day_of_week INTEGER;
  v_slot TIMESTAMP WITH TIME ZONE;
  v_now TIMESTAMP WITH TIME ZONE;
  v_min_time TIMESTAMP WITH TIME ZONE;
BEGIN
  v_now := NOW() AT TIME ZONE 'Europe/Madrid';
  v_min_time := v_now + (p_min_anticipacion_horas || ' hours')::INTERVAL;
  v_day_of_week := EXTRACT(DOW FROM p_fecha);
  IF v_day_of_week IN (0, 6) THEN RETURN; END IF;
  
  FOR i IN 0..6 LOOP
    v_slot := (p_fecha || ' ' || (10 + (i / 2)) || ':' || 
               CASE WHEN i % 2 = 0 THEN '00' ELSE '30' END || 
               ':00')::TIMESTAMP AT TIME ZONE 'Europe/Madrid';
    IF v_slot > v_min_time AND is_slot_available(v_slot) THEN
      slot_time := v_slot;
      RETURN NEXT;
    END IF;
  END LOOP;
  
  FOR i IN 0..2 LOOP
    v_slot := (p_fecha || ' ' || (16 + (i / 2)) || ':' || 
               CASE WHEN i % 2 = 0 THEN '00' ELSE '30' END || 
               ':00')::TIMESTAMP AT TIME ZONE 'Europe/Madrid';
    IF v_slot > v_min_time AND is_slot_available(v_slot) THEN
      slot_time := v_slot;
      RETURN NEXT;
    END IF;
  END LOOP;
  
  RETURN;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCIÓN: upsert_lead
-- Inserta o actualiza un lead
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_lead(
  p_nombre TEXT,
  p_empresa TEXT,
  p_email TEXT,
  p_necesidad_principal TEXT,
  p_session_id TEXT,
  p_telefono TEXT DEFAULT NULL,
  p_sector TEXT DEFAULT NULL,
  p_tamano_empresa TEXT DEFAULT NULL,
  p_cualificado BOOLEAN DEFAULT false
)
RETURNS UUID AS $$
DECLARE
  v_lead_id UUID;
BEGIN
  INSERT INTO leads (
    nombre, empresa, email, necesidad_principal, session_id,
    telefono, sector, tamano_empresa, cualificado
  )
  VALUES (
    p_nombre, p_empresa, p_email, p_necesidad_principal, p_session_id,
    p_telefono, p_sector, p_tamano_empresa, p_cualificado
  )
  ON CONFLICT (email) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    empresa = EXCLUDED.empresa,
    necesidad_principal = EXCLUDED.necesidad_principal,
    session_id = EXCLUDED.session_id,
    telefono = COALESCE(EXCLUDED.telefono, leads.telefono),
    sector = COALESCE(EXCLUDED.sector, leads.sector),
    tamano_empresa = COALESCE(EXCLUDED.tamano_empresa, leads.tamano_empresa),
    cualificado = EXCLUDED.cualificado,
    updated_at = NOW()
  RETURNING id INTO v_lead_id;
  
  RETURN v_lead_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCIÓN CRÍTICA: create_appointment_with_email
-- Crea appointment vinculado al lead (busca por email)
-- Esta función la llama n8n via RPC
-- ============================================================
CREATE OR REPLACE FUNCTION create_appointment_with_email(
  p_email TEXT,
  p_fecha_hora TIMESTAMPTZ,
  p_duracion INT DEFAULT 30,
  p_estado TEXT DEFAULT 'confirmada',
  p_notas TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
  v_lead_id UUID;
  v_appointment_id UUID;
BEGIN
  -- Buscar el lead por email
  SELECT id INTO v_lead_id FROM leads WHERE email = p_email;
  
  -- Crear el appointment vinculado
  INSERT INTO appointments (lead_id, fecha_hora, duracion_minutos, estado, notas)
  VALUES (v_lead_id, p_fecha_hora, p_duracion, p_estado, p_notas)
  RETURNING id INTO v_appointment_id;
  
  RETURN json_build_object(
    'appointment_id', v_appointment_id,
    'lead_id', v_lead_id,
    'fecha_hora', p_fecha_hora,
    'estado', p_estado
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FIN DEL SCRIPT
-- ============================================================
