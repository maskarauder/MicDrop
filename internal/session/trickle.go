package session

// The initial exchange is deliberately retired at the first ICE restart.
// Late HTTP deliveries cannot add old candidates to renewed credentials.
func (s *Server) trickleVersion() int {
	if s.trickle != nil && s.recovery.generation == 0 {
		return 1
	}
	return 0
}

func (s *Server) continuousVersion() int {
	if s.continuous != nil {
		return 1
	}
	return 0
}
func (s *Server) initialTrickleVersion() int {
	if s.continuous != nil {
		return 1
	}
	return s.trickleVersion()
}
func (s *Server) gatheringVersion() int {
	if s.initialTrickleVersion() == 1 {
		return 3
	}
	return 2
}
