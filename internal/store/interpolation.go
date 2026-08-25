package store

import "github.com/cqagc/voyager2/internal/domain"

const secondsPerDay = 86400.0

func interpolateHermite(
	lower domain.StateVector,
	upper domain.StateVector,
	jd float64,
) domain.StateVector {
	durationSeconds := (upper.JDTDB - lower.JDTDB) * secondsPerDay
	t := (jd - lower.JDTDB) / (upper.JDTDB - lower.JDTDB)

	positionX, velocityX := interpolateComponent(
		lower.Pos.X, lower.Vel.X, upper.Pos.X, upper.Vel.X, durationSeconds, t,
	)
	positionY, velocityY := interpolateComponent(
		lower.Pos.Y, lower.Vel.Y, upper.Pos.Y, upper.Vel.Y, durationSeconds, t,
	)
	positionZ, velocityZ := interpolateComponent(
		lower.Pos.Z, lower.Vel.Z, upper.Pos.Z, upper.Vel.Z, durationSeconds, t,
	)
	return domain.StateVector{
		JDTDB: jd,
		Pos: domain.Vec3{
			X: positionX,
			Y: positionY,
			Z: positionZ,
		},
		Vel: domain.Vec3{
			X: velocityX,
			Y: velocityY,
			Z: velocityZ,
		},
	}
}

func interpolateComponent(p0, v0, p1, v1, durationSeconds, t float64) (float64, float64) {
	t2 := t * t
	t3 := t2 * t
	h00 := 2*t3 - 3*t2 + 1
	h10 := t3 - 2*t2 + t
	h01 := -2*t3 + 3*t2
	h11 := t3 - t2
	position := h00*p0 + h10*durationSeconds*v0 + h01*p1 + h11*durationSeconds*v1

	dh00 := 6*t2 - 6*t
	dh10 := 3*t2 - 4*t + 1
	dh01 := -6*t2 + 6*t
	dh11 := 3*t2 - 2*t
	velocity := (dh00*p0 + dh10*durationSeconds*v0 + dh01*p1 + dh11*durationSeconds*v1) /
		durationSeconds
	return position, velocity
}
