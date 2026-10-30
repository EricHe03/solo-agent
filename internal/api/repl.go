package api

import (
	"context"
	"time"

	swiptv1 "github.com/swipt-automation/swipt/internal/api/gen/swipt/v1"
	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/automation/declarations"
	"google.golang.org/grpc"
)

type replService struct {
	swiptv1.UnimplementedREPLServiceServer
	*Server
}

func (s *replService) Execute(request *swiptv1.ExecuteRequest, stream grpc.ServerStreamingServer[swiptv1.ExecuteResponse]) error {
	ctx := stream.Context()
	session, err := s.cliSession()
	if err != nil {
		return err
	}
	var sendErr error
	err = session.Execute(ctx, request.Code, time.Duration(request.TimeoutMs)*time.Millisecond, func(output automation.Output) {
		if sendErr != nil {
			return
		}
		response := &swiptv1.ExecuteResponse{}
		switch output.Kind {
		case automation.OutputImage:
			response.Part = &swiptv1.ExecuteResponse_Image{Image: output.Image}
		case automation.OutputValue:
			response.Part = &swiptv1.ExecuteResponse_Value{Value: &swiptv1.ScriptValue{Json: string(output.JSON), Text: output.Text}}
		default:
			response.Part = &swiptv1.ExecuteResponse_Console{Console: &swiptv1.ConsoleOutput{Level: logLevel(output.Level), Text: output.Text}}
		}
		sendErr = stream.Send(response)
	})
	if sendErr != nil {
		return sendErr
	}
	if revoked := revocation(ctx); revoked != nil {
		return revoked
	}
	if err == nil {
		return nil
	}
	failure, isFailure := automation.ScriptFailure(err)
	if !isFailure {
		return apiError(err)
	}
	return stream.Send(&swiptv1.ExecuteResponse{Part: &swiptv1.ExecuteResponse_Error{Error: scriptError(failure)}})
}

func (s *replService) Reset(ctx context.Context, _ *swiptv1.ResetRequest) (*swiptv1.ResetResponse, error) {
	session, err := s.cliSession()
	if err != nil {
		return nil, err
	}
	if err = session.Reset(ctx); err != nil {
		return nil, apiError(err)
	}
	return &swiptv1.ResetResponse{}, nil
}

func (s *replService) GetDeclarations(context.Context, *swiptv1.GetDeclarationsRequest) (*swiptv1.GetDeclarationsResponse, error) {
	return &swiptv1.GetDeclarationsResponse{Typescript: declarations.TypeScript}, nil
}
