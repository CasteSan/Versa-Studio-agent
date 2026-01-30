# 🎯 Decisiones Técnicas

> Documentación de las decisiones de diseño y trade-offs del proyecto

---

## Decisión 1: Máquina de estados en Prompt vs Nodos

### Contexto
Necesitaba implementar un flujo conversacional con 7 estados diferentes (SALUDO → CUALIFICACIÓN → CONFIRMAR → AGENDAR → etc.)

### Opciones consideradas

| Opción | Pros | Contras |
|--------|------|---------|
| **Nodos Switch en n8n** | Trazabilidad explícita, fácil de debuggear | Rígido, no maneja casos ambiguos |
| **System Prompt** | Flexible, transiciones naturales | Menos control explícito |

### Decisión
**System Prompt** - Toda la lógica de estados vive en el prompt.

### Justificación
El LLM maneja mejor casos como: *"Soy Carlos de TechFlow, necesito logo y quiero cita mañana"* - que salta varios estados a la vez de forma natural.

### Consecuencias
- ✅ Conversaciones más naturales
- ✅ Fácil de modificar (solo texto)
- ⚠️ Menos trazabilidad del estado actual

---

## Decisión 2: Vertex AI sobre OpenRouter/Google AI Studio

### Contexto
Necesitaba un LLM para el agente. La prueba sugería usar modelos gratuitos.

### Opciones probadas

| Opción | Resultado |
|--------|-----------|
| OpenRouter (Gemini free) | Rate limit tras ~10 requests |
| Google AI Studio | Rate limit similar |
| **Google Vertex AI** | Funciona con $300 créditos GCP |

### Decisión
**Google Vertex AI** con Gemini 1.5 Pro.

### Justificación
Los free tiers de OpenRouter y AI Studio tienen límites muy agresivos para desarrollo iterativo. Cada prueba del agente puede consumir 3-4 llamadas al LLM.

### Consecuencias
- ✅ Sin interrupciones por rate limits
- ✅ Mejor experiencia de desarrollo
- ⚠️ Requiere cuenta de Google Cloud

---

## Decisión 3: Función SQL para vincular appointments

### Contexto
Cuando el agente crea una cita, necesita vincularla al lead. Pero el agente no tiene el UUID del lead, solo el email.

### Opciones consideradas

| Opción | Complejidad | Llamadas HTTP |
|--------|-------------|---------------|
| Dos llamadas desde n8n | Alta | 2 (buscar + crear) |
| **Función RPC en Supabase** | Media | 1 |
| No vincular (lead_id = NULL) | Baja | 1 |

### Decisión
**Función `create_appointment_with_email()`** en Supabase.

### Justificación
```sql
CREATE FUNCTION create_appointment_with_email(p_email TEXT, p_fecha_hora TIMESTAMPTZ)
RETURNS JSON AS $$
BEGIN
  -- 1. Busca lead por email
  SELECT id INTO v_lead_id FROM leads WHERE email = p_email;
  -- 2. Crea appointment vinculado
  INSERT INTO appointments (lead_id, ...) VALUES (v_lead_id, ...);
END;
$$
```

Una sola llamada HTTP hace todo. Si falla, no deja datos inconsistentes.

### Consecuencias
- ✅ Menor latencia (1 llamada vs 2)
- ✅ Transacción atómica
- ✅ Lógica encapsulada en la BD
- ⚠️ Requiere conocimiento de PL/pgSQL

---

## Decisión 4: Code Tools vs HTTP Request Tools

### Contexto
n8n ofrece dos formas de crear tools para AI Agents:
- **Code Tools**: JavaScript inline
- **HTTP Request Tools**: Llamadas HTTP declarativas

### Decisión
- **Code Tools** para validaciones puras (fecha, disponibilidad)
- **HTTP Request Tools** para operaciones de BD

### Justificación
| Tipo de operación | Tool elegido | Razón |
|-------------------|--------------|-------|
| `get_current_datetime` | Code | No requiere estado externo |
| `check_slot_availability` | Code | Validación lógica pura |
| `save_lead` | HTTP Request | Necesita credenciales |
| `create_appointment` | HTTP Request | Necesita credenciales |

Los Code Tools no pueden usar credenciales de n8n, así que para llamadas autenticadas a Supabase, HTTP Request Tools son necesarios.

### Consecuencias
- ✅ Separación clara: lógica vs persistencia
- ✅ Las credenciales se manejan correctamente
- ⚠️ Configuración más compleja para HTTP Tools

---

## Decisión 5: Instrucción explícita de orden de tools

### Contexto
El agente llamaba a `create_appointment` antes de `save_lead`, causando que `lead_id` fuera NULL.

### Descubrimiento
Los LLMs optimizan por "resolver la tarea rápido", no por "seguir un orden lógico". No infieren dependencias entre tools.

### Decisión
Añadir instrucción explícita en el System Prompt:
```
IMPORTANTE: SIEMPRE debes llamar a save_lead ANTES de llamar a create_appointment.
```

Y en la descripción del tool:
```
IMPORTANTE: Solo usar DESPUÉS de haber llamado a save_lead.
```

### Consecuencias
- ✅ El orden se respeta
- ✅ Los datos quedan vinculados
- 📝 Lección: nunca asumir que el LLM infiere dependencias

---

## Resumen de Trade-offs

| Decisión | Ganamos | Perdemos |
|----------|---------|----------|
| Estados en prompt | Flexibilidad | Trazabilidad |
| Vertex AI | Estabilidad | Simplicidad de setup |
| Función RPC | Atomicidad | Lógica distribuida |
| Tools mixtos | Claridad | Homogeneidad |
| Orden explícito | Consistencia | Elegancia |

---

*Documentación creada para facilitar el mantenimiento y onboarding de nuevos colaboradores.*
