## Integrantes

- Choconi Mamani Paul
- Mantilla Villaca Joel Matias 
- Viraca Rodriguez Gerson Jared

# Sistema de Base de Datos Nacional para el Control del Contrabando de Hidrocarburos

Proyecto académico del **Taller de Base de Datos (G:2)**, Facultad de Ciencias y Tecnología, Universidad Mayor de San Simón.

## Descripción

En Bolivia, el combustible es un recurso estratégico y subvencionado. Su precio, más bajo que en los países vecinos, incentiva el desvío y el contrabando hacia mercados transfronterizos. Hoy las estaciones de servicio operan con bases de datos fragmentadas por estación y por departamento. Cada punto de venta solo ve sus propias transacciones, y eso deja "puntos ciegos" que los contrabandistas aprovechan con **cargas fraccionadas**: compras pequeñas y aparentemente legales repartidas entre distintas estaciones, horarios y zonas.

Este repositorio busca resolver esa problemática con el **diseño e implementación de una Base de Datos Nacional Unificada**. La base integra la información de consumidores, vehículos, estaciones de servicio y transacciones, para detectar automáticamente patrones irregulares de abastecimiento.

## Objetivo

Diseñar un modelo de base de datos relacional que permita:

- Vincular de forma integral al **consumidor**, el **vehículo** y la **estación de servicio** en cada transacción.
- Consolidar el **historial nacional** de cargas de cada usuario y vehículo.
- Generar **alertas automáticas** ante comportamientos sospechosos.
- Aplicar **reglas de control dinámicas y parametrizables** que puedan cambiar con el tiempo sin perder la trazabilidad histórica.

## Funcionamiento general

El sistema trabaja en tres etapas:

1. **Registro integral:** vincula al consumidor (CI, datos de contacto), el vehículo (placa, capacidad del tanque) y la estación de servicio.
2. **Análisis de historial:** consulta el comportamiento del par usuario-vehículo a nivel nacional, no solo por estación.
3. **Generación de alertas:** notifica o bloquea automáticamente cuando detecta patrones irregulares.

## Criterios de detección de anomalías

| Criterio | Ejemplo de alerta |
|---|---|
| Exceso de volumen | El vehículo supera el límite permitido en un periodo determinado |
| Múltiples estaciones | Un mismo vehículo carga en varias estaciones el mismo día |
| Frecuencia de abastecimiento | Muchas más cargas de las habituales en pocos días |
| Capacidad del tanque | Volumen cargado incompatible con la capacidad registrada del vehículo |
| Ubicación geográfica | Cargas en ciudades distantes en un intervalo de tiempo imposible |

## Consideraciones de diseño

- **Reglas temporales:** la base de datos guarda la regla vigente en la fecha y hora exacta de cada transacción. Una carga histórica no se evalúa con la normativa actual.
- **Umbrales parametrizables:** los límites dependen de variables como ubicación, frecuencia y tipo de vehículo, en lugar de un promedio estático.

## Tecnologías

- **Oracle Database** como gestor de base de datos relacional
- **SQL** para la definición y consulta de datos
- **PL/SQL** para procedimientos almacenados y *triggers* que automatizan las validaciones y alertas
